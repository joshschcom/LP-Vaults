AVAX_RPC ?= https://avax-mainnet.g.alchemy.com/v2/Wb-qwqnC_yZRQOAAs7PCjISOT7xYgcuN
FUJI_RPC ?= https://api.avax-test.network/ext/bc/C/rpc
DEPLOYER ?= 0x000000000000000000000000000000000000dEaD
MULTISIG ?= $(DEPLOYER)
KEEPER ?= $(DEPLOYER)
FORK_BLOCK ?= $(shell cast block-number --rpc-url $(AVAX_RPC))

.PHONY: build test test-lfj-fork test-lfj-fork-pinned deploy-lfj-proxy-dry-run deploy-lfj-proxy-mainnet deploy-lfj-dry-run deploy-lfj-mainnet check-lfj apy-snapshot apy-compare

build:
	forge build

test:
	forge test

test-lfj-fork:
	forge test --fork-url $(AVAX_RPC) --match-contract LFJStableVaultMainnetForkTest -vvv

test-lfj-fork-pinned:
	forge test --fork-url $(AVAX_RPC) --fork-block-number $(FORK_BLOCK) --match-contract LFJStableVaultMainnetForkTest -vvv

deploy-lfj-proxy-dry-run:
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) forge script script/Deploy.s.sol:DeployMainnet --rpc-url $(AVAX_RPC) -vvv

deploy-lfj-proxy-mainnet:
	DEPLOYER=$(DEPLOYER) MULTISIG=$(MULTISIG) KEEPER=$(KEEPER) forge script script/Deploy.s.sol:DeployMainnet --rpc-url $(AVAX_RPC) --broadcast --verify --private-key $(PRIVATE_KEY) -vvv

deploy-lfj-dry-run: deploy-lfj-proxy-dry-run

deploy-lfj-mainnet: deploy-lfj-proxy-mainnet

check-lfj:
	./scripts/post-deploy-check.sh

apy-snapshot:
	./scripts/apy-snapshot.sh

apy-compare:
	./scripts/apy-snapshot.sh --compare
