{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards           #-}
--------------------------------------------------------------------------------
-- |
-- Module : Database.EventStore.Internal.Manager.Operation.Model
-- Copyright : (C) 2015 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
-- Main operation bookkeeping structure.
--------------------------------------------------------------------------------
module Database.EventStore.Internal.Manager.Operation.Model
    ( Model
    , Transition(..)
    , newModel
    , pushOperation
    , submitPackage
    , abort
    ) where

--------------------------------------------------------------------------------
import Data.Word

--------------------------------------------------------------------------------
import qualified Data.HashMap.Strict  as H
import           Data.ProtocolBuffers
import           Data.Serialize
import           Data.UUID

--------------------------------------------------------------------------------
import Database.EventStore.Internal.Generator
import Database.EventStore.Internal.Operation
import Database.EventStore.Internal.Types

--------------------------------------------------------------------------------
-- | Entry of a running 'Operation'.
data Elem r =
    forall a resp. Decode resp =>
    Elem
    { _opOp   :: Operation a
    , _opCmd  :: Word8
    , _opCont :: resp -> SM a ()
    , _opCb   :: Either OperationError a -> r
    }

--------------------------------------------------------------------------------
-- | Operation internal state.
data State r =
    State
    { _gen :: Generator
      -- ^ 'UUID' generator.
    , _pending :: H.HashMap UUID (Elem r)
      -- ^ Contains all running 'Operation's.
    }

--------------------------------------------------------------------------------
initState :: Generator -> State r
initState g = State g H.empty

--------------------------------------------------------------------------------
-- | Type of requests handled by the model.
data Request r
    = forall a. New (Operation a) (Either OperationError a -> r)
      -- ^ Register a new 'Operation'.
    | Pkg Package
      -- ^ Submit a package.
    | Abort
      -- ^ Aborts every pending operation.

--------------------------------------------------------------------------------
-- | Output produces by the interpretation of an 'Operation'.
data Transition r
    = Produce r (Transition r)
      -- ^ Produces an intermediary value.
    | Transmit Package (Transition r)
      -- ^ Asks for sending the given 'Package'.
    | Await (Model r)
      -- ^ waits for more input.

--------------------------------------------------------------------------------
-- | Main 'Operation' bookkeeping state machine.
newtype Model r = Model (Request r -> Maybe (Transition r))

--------------------------------------------------------------------------------
-- | Pushes a new 'Operation' to model. The given 'Operation' state-machine is
--   initialized and produces a 'Package'.
pushOperation :: (Either OperationError a -> r)
              -> Operation a
              -> Model r
              -> Transition r
pushOperation cb op (Model k) = let Just t = k (New op cb) in t

--------------------------------------------------------------------------------
-- | Submits a 'Package' to the model. If the model isn't concerned by the
--   'Package', it will returns 'Nothing'. Because 'Operation' can implement
--   complex logic (retry for instance), it returns a 'Step'.
submitPackage :: Package -> Model r -> Maybe (Transition r)
submitPackage pkg (Model k) = k (Pkg pkg)

--------------------------------------------------------------------------------
-- | Aborts every pending operation.
abort :: Model r -> Transition r
abort (Model k) = let Just t = k Abort in t

--------------------------------------------------------------------------------
runOperation :: Settings
             -> (Either OperationError a -> r)
             -> Operation a
             -> SM a ()
             -> State r
             -> Transition r
runOperation setts cb op start init_st = go init_st start
  where
    go st (Return _) = Await $ Model $ handle setts st
    go st (Yield a n) = Produce (cb $ Right a) (go st n)
    go st (FreshId k) =
        let (new_id, nxt_gen) = nextUUID $ _gen st
            nxt_st            = st { _gen = nxt_gen } in
        go nxt_st $ k new_id
    go st (SendPkg ci co rq k) =
        let (new_uuid, nxt_gen) = nextUUID $ _gen st
            pkg = Package
                  { packageCmd         = ci
                  , packageCorrelation = new_uuid
                  , packageData        = runPut $ encodeMessage rq
                  , packageCred        = s_credentials setts
                  }
            elm    = Elem op co k cb
            ps     = H.insert new_uuid elm $ _pending st
            nxt_st = st { _pending = ps
                        , _gen     = nxt_gen
                        } in
        Transmit pkg (Await $ Model $ handle setts nxt_st)
    go st (Failure m) =
        case m of
            Just e -> Produce (cb $ Left e) (Await $ Model $ handle setts st)
            _      -> runOperation setts cb op op st

--------------------------------------------------------------------------------
runPackage :: Settings -> State r -> Package -> Maybe (Transition r)
runPackage setts st Package{..} = do
    Elem op resp_cmd cont cb <- H.lookup packageCorrelation $ _pending st
    let nxt_ps = H.delete packageCorrelation $ _pending st
        nxt_st = st { _pending = nxt_ps }
    if resp_cmd /= packageCmd
        then
            let r = cb $ Left $ InvalidServerResponse resp_cmd packageCmd in
            return $ Produce r (Await $ Model $ handle setts nxt_st)
        else
            case runGet decodeMessage packageData of
                Left e  ->
                    let r = cb $ Left $ ProtobufDecodingError e in
                    return $ Produce r (Await $ Model $ handle setts nxt_st)
                Right m -> return $ runOperation setts cb op (cont m) nxt_st

--------------------------------------------------------------------------------
abortOperations :: Settings -> State r -> Transition r
abortOperations setts init_st = go init_st $ H.toList $ _pending init_st
  where
    go st ((key, Elem _ _ _ k):xs) =
        let ps     = H.delete key $ _pending st
            nxt_st = st { _pending = ps } in
        Produce (k $ Left Aborted) $ go nxt_st xs
    go st [] = Await $ Model $ handle setts st

--------------------------------------------------------------------------------
-- | Creates a new 'Operation' model state-machine.
newModel :: Settings -> Generator -> Model r
newModel setts g = Model $ handle setts $ initState g

--------------------------------------------------------------------------------
handle :: Settings -> State r -> Request r -> Maybe (Transition r)
handle setts st (New op cb) = Just $ runOperation setts cb op op st
handle setts st (Pkg pkg)   = runPackage setts st pkg
handle setts st Abort       = Just $ abortOperations setts st
