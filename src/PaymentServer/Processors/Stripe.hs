{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PaymentServer.Processors.Stripe
  ( StripeAPI
  , Charges(Charges)
  , Acknowledgement(Ok)
  , Failure(Failure)
  , stripeServer
  , getVoucher
  , charge
  ) where

import Prelude hiding
  ( concat
  )

import Control.Exception
  ( catch
  )
import Control.Monad.IO.Class
  ( liftIO
  )
import Control.Monad
  ( mzero
  )
import Data.Text
  ( Text
  , unpack
  , concat
  )
import Text.Read
  ( readMaybe
  )

import Network.HTTP.Types
  ( Status(Status)
  , status400
  , status500
  , status503
  )

import Data.ByteString.UTF8
  ( toString
  )

import Data.Aeson
  ( ToJSON(toJSON)
  , FromJSON(parseJSON)
  , Value(Object)
  , object
  , encode
  , (.:)
  , (.=)
  )
import Servant
  ( Server
  , Handler
  , ServerError(ServerError, errHTTPCode, errBody, errHeaders, errReasonPhrase)
  , throwError
  )
import Servant.API
  ( ReqBody
  , JSON
  , Post
  , (:>)
  )
import Web.Stripe.Error
  ( StripeError(StripeError, errorType, errorMsg)
  , StripeErrorType(InvalidRequest, APIError, ConnectionFailure, CardError)
  )
import Web.Stripe.Types
  ( Charge(Charge, chargeId)
  , MetaData(MetaData)
  , Currency(USD)
  )
import Web.Stripe.Charge
  ( createCharge
  , Amount(Amount)
  , TokenId(TokenId)
  )
import Web.Stripe.Client
  ( StripeConfig
  )
import Web.Stripe
  ( stripe
  , (-&-)
  )

import qualified Prometheus as P

import PaymentServer.Persistence
  ( Voucher
  , VoucherDatabase(payForVoucher)
  , PaymentError(AlreadyPaid, PaymentFailed)
  , ProcessorResult
  )

data Acknowledgement = Ok deriving (Eq, Show)

instance ToJSON Acknowledgement where
  toJSON Ok = object
    [ "success" .= True
    ]

type StripeAPI = ChargesAPI

-- | getVoucher finds the metadata item with the key `"Voucher"` and returns
-- the corresponding value, or Nothing.
getVoucher :: MetaData -> Maybe Voucher
getVoucher (MetaData []) = Nothing
getVoucher (MetaData (("Voucher", value):xs)) = Just value
getVoucher (MetaData (x:xs)) = getVoucher (MetaData xs)

stripeServer :: VoucherDatabase d => StripeConfig -> d -> Server StripeAPI
stripeServer stripeConfig d =
  withSuccessFailureMetrics chargeAttempts chargeSuccesses . charge stripeConfig d

-- | Browser facing API that takes token, voucher and a few other information
-- and calls stripe charges API. If payment succeeds, then the voucher is stored
-- in the voucher database.
type ChargesAPI = "charge" :> ReqBody '[JSON] Charges :> Post '[JSON] Acknowledgement

data Charges = Charges
  { token :: Text          -- ^ The text of a Stripe tokenized payment method.
  , voucher :: Voucher     -- ^ The voucher for which this charge will pay.
  , amount :: Int          -- ^ The amount of the charge in the minimum
                           -- currency unit of the target currency (eg for
                           -- USD, cents).
  , currency :: Currency   -- ^ The currency in which the charge will be made.
  } deriving (Show, Eq)

instance FromJSON Charges where
  parseJSON (Object v) = Charges <$>
                         v .: "token" <*>
                         v .: "voucher" <*>
                         (read <$> v .: "amount") <*>
                         (read <$> v .: "currency")
  parseJSON _ = mzero


metricName :: Text -> Text
metricName name = mappend ("payment_processors_stripe_charge_") name

chargeAttempts :: P.Counter
chargeAttempts
  = P.unsafeRegister
  $ P.counter
  $ P.Info (metricName "attempts")
  "The number of attempted charge requests received."


chargeSuccesses :: P.Counter
chargeSuccesses
  = P.unsafeRegister
  $ P.counter
  $ P.Info (metricName "successes")
  "The number of charge requests successfully processed."


-- | run a Servant Handler, recording the attempt and whether or not it
-- succeeds using the given counters.
withSuccessFailureMetrics :: P.Counter -> P.Counter -> Handler a -> Handler a
withSuccessFailureMetrics attemptCount successCount op = do
  liftIO $ P.incCounter attemptCount
  result <- op
  liftIO $ P.incCounter successCount
  return result


-- | call the stripe Charge API (with token, voucher in metadata, amount, currency etc
-- and if the Charge is okay, then set the voucher as "paid" in the database.
charge :: VoucherDatabase d => StripeConfig -> d -> Charges -> Handler Acknowledgement
charge stripeConfig d (Charges token voucher 650 USD) = do
  result <- liftIO payForVoucher'
  case result of
    Left AlreadyPaid ->
      throwError $ voucherAlreadyPaid "Payment for voucher already supplied"

    Left (PaymentFailed (StripeError { errorType = errorType, errorMsg = msg })) -> do
      liftIO $ print "Stripe createCharge failed:"
      liftIO $ print msg
      let err = errorForStripe errorType ( concat [ "Stripe charge didn't succeed: ", msg ])
      throwError err

    Right chargeId -> return Ok

    where
      payForVoucher' :: IO ProcessorResult
      payForVoucher' = do
        payForVoucher d voucher (completeStripeCharge USD) `catch` (
          \(e :: PaymentError) -> return $ Left e
          )

      tokenId = TokenId token
      completeStripeCharge :: Currency -> IO ProcessorResult
      completeStripeCharge currency = do
        result <- stripe stripeConfig charge
        case result of
          Left any ->
            return . Left $ PaymentFailed any
          Right (Charge { chargeId }) ->
            return . Right $ chargeId
          where
          charge =
            createCharge (Amount 650) currency
            -&- tokenId
            -&- MetaData [("Voucher", voucher)]

      -- "Invalid request errors arise when your request has invalid parameters."
      errorForStripe InvalidRequest    = internalServerError

      -- "API errors cover any other type of problem (e.g., a temporary
      -- problem with Stripe's servers), and are extremely uncommon."
      errorForStripe APIError          = serviceUnavailable

      -- "Failure to connect to Stripe's API."
      errorForStripe ConnectionFailure = serviceUnavailable

      -- "Card errors are the most common type of error you should expect to
      -- handle. They result when the user enters a card that can't be charged
      -- for some reason."
      errorForStripe CardError         = stripeChargeFailed

      -- Something else we don't know about...
      errorForStripe _                 = internalServerError

      serviceUnavailable  = jsonErr status503
      internalServerError = jsonErr status500
      stripeChargeFailed  = jsonErr status400
      voucherAlreadyPaid  = jsonErr status400

-- The wrong currency
charge _ _ (Charges _ _ 650 _) = throwError (jsonErr status400 "Unsupported currency")
-- The wrong amount
charge _ _ (Charges _ _ _ USD) = throwError (jsonErr status400 "Incorrect charge amount")

jsonErr :: Status -> Text -> ServerError
jsonErr (Status statusCode statusMessage) detail = ServerError
  { errHTTPCode = statusCode
  , errReasonPhrase = toString statusMessage
  , errBody = encode $ Failure detail
  , errHeaders = [("content-type", "application/json")]
  }

data Failure = Failure Text
  deriving (Show, Eq)

instance ToJSON Failure where
  toJSON (Failure reason) = object
    [ "success" .= False
    , "reason" .= reason
    ]

instance FromJSON Failure where
  parseJSON (Object v) = Failure <$>
                         v .: "reason"
  parseJSON _ = mzero
