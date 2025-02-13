-- SPDX-FileCopyrightText: 2021 Tezos Commons
-- SPDX-License-Identifier: LicenseRef-MIT-TC

module SMT.Common.Run
  ( runBaseDaoSMT
  ) where

import Universum hiding (drop, swap)

import Data.Map qualified as Map
import Data.Typeable (eqT, (:~:)(..))
import Fmt (Buildable, build, pretty, unlinesF)
import Hedgehog hiding (assert)

import Lorentz hiding (assert, now, (>>))
import Lorentz.Contracts.Spec.FA2Interface qualified as FA2
import Morley.Micheline qualified as MM
import Morley.Michelson.Runtime.Dummy (dummyLevel)
import Morley.Michelson.Typed qualified as T
import Morley.Michelson.Untyped qualified as U
import Test.Cleveland
import Test.Cleveland.Internal.Abstract
  (ExpressionOrTypedValue(..), TransferFailure(..), TransferFailureReason(..))
import Test.Cleveland.Lorentz (contractConsumer)

import Ligo.BaseDAO.Contract
import Ligo.BaseDAO.RegistryDAO.Types as Registry
import Ligo.BaseDAO.Types
import SMT.Common.Gen
import SMT.Common.Types
import SMT.Model.BaseDAO.Contract
import SMT.Model.BaseDAO.Types
import Test.Ligo.BaseDAO.Common

-- | The functions run the generator to get a list of entrypoints
-- and do setups before calling entrypoints againts ligo and haskell model
-- For Ligo:
--   - Setup initial level (generated by the generator)
--   - Originate auxiliary contracts
--   - Originate basedao contract
-- For Haskell:
--   - Setup `ModelState`
runBaseDaoSMT :: forall var. (Typeable var, IsoValue (VariantToExtra var), Default (VariantToExtra var), T.HasNoOp (ToT (VariantToExtra var))) => SmtOption var -> PropertyT IO ()
runBaseDaoSMT option@SmtOption{..} = do

  -- Run the generator to get a function that will generate a list of entrypoint calls.
  mkModelInput <- forAll (runGeneratorT (genMkModelInput @var option) $ initGeneratorState soMkPropose)

  testScenarioProps $
    (scenarioEmulated $ do
        -- Originate auxiliary contracts
        guardianContract <- originate "guardian" () dummyGuardianContract
        tokenContract <- originate "TokenContract" [] dummyFA2Contract
        fa12TokenContract <- originate "FA12TokenContract" [] dummyFA12Contract
        registryDaoConsumer <- originate "registryDaoConsumer" []
          (contractConsumer @(MText, (Maybe MText))) -- Used in registry dao.

        -- Generate a list of entrypoint calls
        let
          ModelInput (contractCalls, ms) = mkModelInput $ ModelInputArg
              { miaGuardianAddr = toAddress guardianContract
              , miaGovAddr = toAddress tokenContract
              , miaViewContractAddr = registryDaoConsumer
              }

        -- Sync current level to start level in contract initial storage
        -- as well as in the model state
        let currentLevel = (dummyLevel + (ms & msLevel))

        let (fullStorage :: StorageSkeleton (VariantToExtra var)) = msStorage ms
        let storage :: StorageSkeleton (VariantToExtra var) = fullStorage { sStartLevel = currentLevel, sExtra = sExtra fullStorage }

        -- Set initial level for the Nettest
        advanceToLevel currentLevel

        -- Modify `Storage` from the generator with registry/treasury configuration.
        let newMs :: ModelState var = ms { msLevel = currentLevel, msStorage = soModifyS storage  }

        -- Preparing proper `ModelState` to be used in Haskell model
        let newMs_ addr bal = newMs
              { msSelfAddress = addr
              , msContracts = Map.fromList
                  [ (toAddress tokenContract, SimpleFA2ContractType $ SimpleFA2Contract [] zeroMutez)
                  , (toAddress fa12TokenContract, SimpleFA12ContractType $ SimpleFA12Contract [] zeroMutez)
                  , (toAddress registryDaoConsumer, OtherContractType $ OtherContract [] zeroMutez)
                  ]
              , msMutez = bal
              , msLevel = currentLevel
              }

        -- Call ligo dao and run haskell model then compare the results.
        case eqT @var @'Base of
          Just Refl -> do
            dao <- originate "BaseDAO" (newMs & msStorage) baseDAOContractLigo
            handleCallLoop @'Base (dao, tokenContract, registryDaoConsumer) contractCalls (newMs_ (toAddress dao) zeroMutez)
          Nothing -> case eqT @var @'Registry of
            Just Refl -> do
              let bal = [tz|500u|]
              dao <- originate "BaseDAO" (newMs & msStorage) baseDAORegistryLigo
              sendXtzWithAmount bal dao
              handleCallLoop @'Registry (dao, tokenContract, registryDaoConsumer) contractCalls (newMs_ (toAddress dao) bal)
            Nothing -> case eqT @var @'Treasury of
              Just Refl -> do
                let bal = [tz|500u|]
                dao <- originate "BaseDAO" (newMs & msStorage) baseDAOTreasuryLigo
                sendXtzWithAmount bal dao
                handleCallLoop @'Treasury (dao, tokenContract, registryDaoConsumer) contractCalls (newMs_ (toAddress dao) bal)
              Nothing -> error "Unknown contract"
    )

-- | For each generated entrypoint calls, this function does 3 things:
-- 1. Run haskell model against the call.
-- 2. Call ligo dao with the call
-- 3. Compare the result. If it is to be expected, loop to the next call, else throw the error.
handleCallLoop
  :: (ContractExtraConstrain (VariantToExtra var), Eq (VariantToExtra var), Buildable (VariantToExtra var), Buildable (VariantToParam var), CallCustomEp (VariantToParam var), HasBaseDAOEp (Parameter' (VariantToParam var)), MonadEmulated caps m)
  => (ContractHandle (Parameter' (VariantToParam var)) (StorageSkeleton (VariantToExtra var)) (), ContractHandle FA2.Parameter [FA2.TransferParams] (), ContractHandle (MText, Maybe MText) [(MText, Maybe MText)] ())
  -> [ModelCall var] -> ModelState var -> m ()
handleCallLoop _ [] _ = pure ()
handleCallLoop (dao, gov, viewC) (mc:mcs) ms = do

  -- All values here are needed for `printResult`. See `printResult` for the usage of the values.
  let (haskellErrors, updatedMs) = handleCallViaHaskell mc ms
      haskellStoreE = case haskellErrors of
        Just err -> Left err
        Nothing -> Right (msStorage updatedMs)
      haskellDaoBalance = msMutez updatedMs

      govContract = updatedMs & msContracts
        & Map.lookup (toAddress gov)
        & fromMaybe (error "Governance contract does not exist")
      haskellGovStore = case govContract of SimpleFA2ContractType c -> c & sfcStorage; _ -> error "Shouldn't happen."
      haskellGovBalance = case govContract of SimpleFA2ContractType c -> c & sfcMutez; _ -> error "Shouldn't happen."

      viewContract = updatedMs & msContracts
        & Map.lookup (toAddress viewC)
        & fromMaybe (error "View contract does not exist")
      haskellViewStore = case viewContract of OtherContractType c -> c & ocStorage; _ -> error "Shouldn't happen."

  (ligoStoreE, ligoDaoBalance, ligoGovStore, ligoGovBalance, ligoViewStore)
    <- handleCallViaLigo (dao, gov, viewC) mc

  printResult mc
    (haskellStoreE, haskellDaoBalance, haskellGovStore, haskellGovBalance, haskellViewStore)
    (ligoStoreE, ligoDaoBalance, ligoGovStore, ligoGovBalance, ligoViewStore)

  handleCallLoop (dao, gov, viewC) mcs updatedMs


-- | Compare dao's storage, error, and balance, and its auxiliary contracts:
--   - an fa2 contract storage and mutez (which is gov contract in this case)
--   - a view contract storage
-- Note: Gov contract does not necessarily have to be the governance contract of basedao.
-- We simply need a FA2 contract to do various operation in the haskell model, and gov contract
-- just happen to be a convenience FA2 contract that we can use.
printResult
  :: (Buildable (VariantToParam var), Buildable (VariantToExtra var), Eq (VariantToExtra var), MonadEmulated caps m)
  => ModelCall var
  -> (Either ModelError (StorageSkeleton (VariantToExtra var)), Mutez, [FA2.TransferParams], Mutez, [Text])
  -> (Either ModelError (StorageSkeleton (VariantToExtra var)), Mutez, [FA2.TransferParams], Mutez, [Text])
  -> m ()
printResult mc
  (haskellStoreE, haskellDaoBalance, haskellGovStore, haskellGovBalance, haskellViewStore)
  (ligoStoreE, ligoDaoBalance, ligoGovStore, ligoGovBalance, ligoViewStore) = do

    assert (haskellStoreE == ligoStoreE) $
      unlinesF
        [ "━━ Error: Haskell and Ligo storage are different ━━"
        , modelCallMsg
        , "━━ Haskell storage ━━"
        , build haskellStoreE
        , "━━ Ligo storage ━━"
        , build ligoStoreE
        ]

    -- Dao contract balance could be updated via treasury/registry xtz proposal.
    assert (haskellDaoBalance == ligoDaoBalance) $
      unlinesF
        [ "━━ Error: Haskell and Ligo dao contract balance are different ━━"
        , modelCallMsg
        , "━━ Haskell dao contract balance ━━"
        , build haskellDaoBalance
        , "━━ Ligo dao contract balance ━━"
        , build ligoDaoBalance
        ]

    assert (haskellGovStore == ligoGovStore) $
      unlinesF
        [ "━━ Error: Haskell and Ligo governance contract storage are different ━━"
        , modelCallMsg
        , "━━ Haskell governance contract storage ━━"
        , build haskellGovStore
        , "━━ Ligo governance contract storage ━━"
        , build ligoGovStore
        ]

    -- Governance contract balance could be updated via treasury/registry transfer proposal.
    assert (haskellGovBalance == ligoGovBalance) $
      unlinesF
        [ "━━ Error: Haskell and Ligo governance contract balance are different ━━"
        , modelCallMsg
        , "━━ Haskell governance contract balance ━━"
        , build haskellGovBalance
        , "━━ Ligo governance contract balance ━━"
        , build ligoGovBalance
        ]

    -- View contract storage could be updated via registry lookup registry call.
    assert (haskellViewStore == ligoViewStore) $
      unlinesF
        [ "━━ Error: Haskell and Ligo view contract storage are different ━━"
        , modelCallMsg
        , "━━ Haskell view contract storage ━━"
        , build haskellViewStore
        , "━━ Ligo view contract storage ━━"
        , build ligoViewStore
        ]

    where
      modelCallMsg = "* Call with:\n" <> (pretty mc)


-- | Advance nettest level and call ligo dao with the provided argument.
-- Return the result of the call (storage or error) and the storage of
-- auxiliary contracts.
handleCallViaLigo
  :: (ContractExtraConstrain (VariantToExtra var), CallCustomEp (VariantToParam var), HasBaseDAOEp (Parameter' (VariantToParam var)), MonadEmulated caps m)
  => (ContractHandle (Parameter' (VariantToParam var)) (StorageSkeleton (VariantToExtra var)) (), ContractHandle FA2.Parameter [FA2.TransferParams] (), ContractHandle (MText, Maybe MText) [(MText, Maybe MText)] ())
  -> ModelCall var
  -> m (Either ModelError (StorageSkeleton (VariantToExtra var)), Mutez, [FA2.TransferParams], Mutez, [Text])
handleCallViaLigo (dao, gov, viewC) mc = do
  case (mc & mcAdvanceLevel) of
    Just lvl -> advanceLevel lvl
    Nothing -> pure ()

  nettestResult <- attempt @TransferFailure $ callLigoEntrypoint mc dao
  let result = parseNettestError nettestResult
  fs <- getFullStorage (chAddress dao)
  let fsE = case result of
        Just err -> Left err
        Nothing -> Right fs

  daoBalance <- getBalance dao

  govStore <- getFullStorage @([FA2.TransferParams]) gov
  govBalance <- getBalance gov

  viewStorage <- getFullStorage @([(MText, Maybe MText)]) viewC
  pure (fsE, daoBalance, govStore, govBalance, show <$> viewStorage)


callLigoEntrypoint ::
  ( CallCustomEp (VariantToParam var), HasBaseDAOEp (Parameter' (VariantToParam var))
  , MonadCleveland caps m
  ) => ModelCall var -> ContractHandle (Parameter' (VariantToParam var)) (StorageSkeleton (VariantToExtra var)) () -> m ()
callLigoEntrypoint mc dao = do
  transfer (mc & mcSource & msoSender) oneMutez
  withSender (mc & mcSource & msoSender) $ case mc & mcParameter of
    XtzAllowed (ConcreteEp (Propose p)) -> transfer dao $ calling (ep @"Propose") p
    XtzAllowed (ConcreteEp (Transfer_contract_tokens p)) -> transfer dao $ calling (ep @"Transfer_contract_tokens") p
    XtzAllowed (ConcreteEp (Transfer_ownership p)) -> transfer dao $ calling (ep @"Transfer_ownership") p
    XtzAllowed (ConcreteEp (Accept_ownership p)) -> transfer dao $ calling (ep @"Accept_ownership") p
    XtzAllowed (ConcreteEp (Default _)) -> transfer dao

    XtzForbidden (Vote p) -> transfer dao $ calling (ep @"Vote") p
    XtzForbidden (Flush p) -> transfer dao $ calling (ep @"Flush") p
    XtzForbidden (Freeze p) -> transfer dao $ calling (ep @"Freeze") p
    XtzForbidden (Unfreeze p) -> transfer dao $ calling (ep @"Unfreeze") p
    XtzForbidden (Update_delegate p) -> transfer dao $ calling (ep @"Update_delegate") p
    XtzForbidden (Drop_proposal p) -> transfer dao $ calling (ep @"Drop_proposal") p
    XtzForbidden (Unstake_vote p) -> transfer dao $ calling (ep @"Unstake_vote") p

    XtzAllowed (CustomEp p) -> callCustomEp dao p

class CallCustomEp p where
  callCustomEp :: MonadCleveland caps m => (ContractHandle (Parameter' p) st vd) -> p -> m ()

instance CallCustomEp () where
  callCustomEp _ _ = pure ()

instance CallCustomEp RegistryCustomEpParam where
  callCustomEp dao p = case p of
    Lookup_registry p_ -> transfer dao $ calling (ep @"Lookup_registry") p_
    _ -> pure ()

parseNettestError :: Either TransferFailure a -> Maybe ModelError
parseNettestError = \case
  Right _ -> Nothing
  Left (tfReason -> FailedWith (EOTVExpression expr) _) -> case MM.fromExpression @U.Value expr of
    Right (U.ValueInt err) -> Just $ contractErrorToModelError err
    Right (U.ValuePair (U.ValueInt err) _) -> Just $ contractErrorToModelError err
    err -> error $ "Unexpected error:" <> show err
  Left (tfReason -> FailedWith (EOTVTypedValue (T.VNat tval)) _) ->
    Just $ contractErrorToModelError $ toInteger tval
  Left (tfReason -> FailedWith (EOTVTypedValue (T.VPair (T.VNat tval, _))) _) ->
    Just $ contractErrorToModelError $ toInteger tval
  Left err -> error $ "Unexpected error:" <> show err
