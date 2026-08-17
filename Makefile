AVAX_RPC ?= https://api.avax.network/ext/bc/C/rpc
FUJI_RPC ?= https://api.avax-test.network/ext/bc/C/rpc
DEPLOYER ?= 0x000000000000000000000000000000000000dEaD
MULTISIG ?= $(DEPLOYER)
KEEPER ?= $(DEPLOYER)
USDC_DEPOSIT_CAP ?= 250000000000
WAVAX_DEPOSIT_CAP ?= 500000000000000000000
FORK_BLOCK ?= $(shell cast block-number --rpc-url $(AVAX_RPC))
PHARAOH_USDT_USDC_POOL ?= 0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0
PHARAOH_SAVAX_WAVAX_POOL ?= 0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD
PHARAOH_OBSERVATION_CARDINALITY ?= 64
LFJ_PRICE_ORACLE ?=
LFJ_VALUATION_HAIRCUT_BPS ?= 200
SIGNER_ARGS ?=

.PHONY: build test test-pharaoh test-peridot-pharaoh-oracle test-pharaoh-fork check-pharaoh-safe-batches grow-pharaoh-observations check-pharaoh-observations deploy-pharaoh-dry-run deploy-pharaoh-mainnet deploy-pharaoh-upgrade-dry-run deploy-pharaoh-upgrade-mainnet prepare-pharaoh-upgrade deploy-pharaoh-hotfix-dry-run deploy-pharaoh-hotfix-mainnet prepare-pharaoh-hotfix deploy-pharaoh-reward-upgrade-dry-run deploy-pharaoh-reward-upgrade-mainnet prepare-pharaoh-reward-upgrade fund-pharaoh-small-stage-dry-run fund-pharaoh-small-stage-mainnet pharaoh-status pharaoh-pnl-snapshot test-lfj-fork test-lfj-fork-pinned deploy-lfj-proxy-dry-run deploy-lfj-proxy-mainnet deploy-lfj-dry-run deploy-lfj-mainnet check-lfj apy-snapshot apy-compare

build:
	forge build

test:
	forge test

test-pharaoh:
	forge test --match-path "test/Pharaoh*.t.sol" -vv

test-peridot-pharaoh-oracle:
	forge test --match-path "test/PeridotPharaohShareOracle.t.sol" -vv

test-pharaoh-fork:
	forge test --fork-url $(AVAX_RPC) --fork-block-number $(FORK_BLOCK) --match-path "test/Pharaoh*MainnetFork.t.sol" -vvv

check-pharaoh-safe-batches:
	./scripts/check-safe-batches.sh

grow-pharaoh-observations:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore'))
	cast send $(PHARAOH_USDT_USDC_POOL) "increaseObservationCardinalityNext(uint16)" $(PHARAOH_OBSERVATION_CARDINALITY) --rpc-url $(AVAX_RPC) $(SIGNER_ARGS)
	cast send $(PHARAOH_SAVAX_WAVAX_POOL) "increaseObservationCardinalityNext(uint16)" $(PHARAOH_OBSERVATION_CARDINALITY) --rpc-url $(AVAX_RPC) $(SIGNER_ARGS)

check-pharaoh-observations:
	cast call $(PHARAOH_USDT_USDC_POOL) "slot0()(uint160,int24,uint16,uint16,uint16,uint24,bool)" --rpc-url $(AVAX_RPC)
	cast call $(PHARAOH_USDT_USDC_POOL) "observe(uint32[])(int56[],uint160[])" "[1800,0]" --rpc-url $(AVAX_RPC)
	cast call $(PHARAOH_SAVAX_WAVAX_POOL) "slot0()(uint160,int24,uint16,uint16,uint16,uint24,bool)" --rpc-url $(AVAX_RPC)
	cast call $(PHARAOH_SAVAX_WAVAX_POOL) "observe(uint32[])(int56[],uint160[])" "[1800,0]" --rpc-url $(AVAX_RPC)

deploy-pharaoh-dry-run:
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) USDC_DEPOSIT_CAP=$(USDC_DEPOSIT_CAP) WAVAX_DEPOSIT_CAP=$(WAVAX_DEPOSIT_CAP) forge script script/DeployPharaoh.s.sol:DeployPharaoh --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-mainnet:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore'))
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) USDC_DEPOSIT_CAP=$(USDC_DEPOSIT_CAP) WAVAX_DEPOSIT_CAP=$(WAVAX_DEPOSIT_CAP) forge script script/DeployPharaoh.s.sol:DeployPharaoh --rpc-url $(AVAX_RPC) --broadcast --verify $(SIGNER_ARGS) -vvv

deploy-pharaoh-upgrade-dry-run:
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohUpgrade.s.sol:DeployPharaohUpgrade --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-upgrade-mainnet:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore --verifier sourcify'))
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohUpgrade.s.sol:DeployPharaohUpgrade --rpc-url $(AVAX_RPC) --broadcast --verify $(SIGNER_ARGS) -vvv

prepare-pharaoh-upgrade:
	$(if $(strip $(NEW_IMPLEMENTATION)),,$(error NEW_IMPLEMENTATION is required))
	NEW_IMPLEMENTATION=$(NEW_IMPLEMENTATION) forge script script/DeployPharaohUpgrade.s.sol:PreparePharaohUpgrade --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-hotfix-dry-run:
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohPartialExitHotfix.s.sol:DeployPharaohPartialExitHotfix --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-hotfix-mainnet:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore --verifier sourcify'))
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohPartialExitHotfix.s.sol:DeployPharaohPartialExitHotfix --rpc-url $(AVAX_RPC) --broadcast --verify $(SIGNER_ARGS) -vvv

prepare-pharaoh-hotfix:
	$(if $(strip $(NEW_IMPLEMENTATION)),,$(error NEW_IMPLEMENTATION is required))
	NEW_IMPLEMENTATION=$(NEW_IMPLEMENTATION) forge script script/DeployPharaohPartialExitHotfix.s.sol:PreparePharaohPartialExitHotfix --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-reward-upgrade-dry-run:
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohRewardExtension.s.sol:DeployPharaohRewardExtension --rpc-url $(AVAX_RPC) -vvv

deploy-pharaoh-reward-upgrade-mainnet:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore --verifier sourcify'))
	DEPLOYER=$(DEPLOYER) forge script script/DeployPharaohRewardExtension.s.sol:DeployPharaohRewardExtension --rpc-url $(AVAX_RPC) --broadcast --verify $(SIGNER_ARGS) -vvv

prepare-pharaoh-reward-upgrade:
	$(if $(strip $(NEW_IMPLEMENTATION)),,$(error NEW_IMPLEMENTATION is required))
	NEW_IMPLEMENTATION=$(NEW_IMPLEMENTATION) forge script script/DeployPharaohRewardExtension.s.sol:PreparePharaohRewardExtension --rpc-url $(AVAX_RPC) -vvv

fund-pharaoh-small-stage-dry-run:
	DEPLOYER=$(DEPLOYER) forge script script/FundPharaohSmallStage.s.sol:FundPharaohSmallStage --rpc-url $(AVAX_RPC) -vvv

fund-pharaoh-small-stage-mainnet:
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore'))
	DEPLOYER=$(DEPLOYER) forge script script/FundPharaohSmallStage.s.sol:FundPharaohSmallStage --rpc-url $(AVAX_RPC) --broadcast $(SIGNER_ARGS) -vvv

pharaoh-status:
	RPC=$(AVAX_RPC) ./scripts/pharaoh-pnl.sh

pharaoh-pnl-snapshot:
	RPC=$(AVAX_RPC) ./scripts/pharaoh-pnl.sh --snapshot

test-lfj-fork:
	forge test --fork-url $(AVAX_RPC) --match-contract LFJStableVaultMainnetForkTest -vvv

test-lfj-fork-pinned:
	forge test --fork-url $(AVAX_RPC) --fork-block-number $(FORK_BLOCK) --match-contract LFJStableVaultMainnetForkTest -vvv

deploy-lfj-proxy-dry-run:
	$(if $(strip $(LFJ_PRICE_ORACLE)),,$(error LFJ_PRICE_ORACLE is required))
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) LFJ_PRICE_ORACLE=$(LFJ_PRICE_ORACLE) LFJ_VALUATION_HAIRCUT_BPS=$(LFJ_VALUATION_HAIRCUT_BPS) forge script script/Deploy.s.sol:DeployMainnet --rpc-url $(AVAX_RPC) -vvv

deploy-lfj-proxy-mainnet:
	$(if $(strip $(LFJ_PRICE_ORACLE)),,$(error LFJ_PRICE_ORACLE is required))
	$(if $(strip $(SIGNER_ARGS)),,$(error SIGNER_ARGS is required, for example SIGNER_ARGS='--account my-keystore'))
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) LFJ_PRICE_ORACLE=$(LFJ_PRICE_ORACLE) LFJ_VALUATION_HAIRCUT_BPS=$(LFJ_VALUATION_HAIRCUT_BPS) forge script script/Deploy.s.sol:DeployMainnet --rpc-url $(AVAX_RPC) --broadcast --verify $(SIGNER_ARGS) -vvv

deploy-lfj-dry-run: deploy-lfj-proxy-dry-run

deploy-lfj-mainnet: deploy-lfj-proxy-mainnet

check-lfj:
	./scripts/post-deploy-check.sh

apy-snapshot:
	./scripts/apy-snapshot.sh

apy-compare:
	./scripts/apy-snapshot.sh --compare
