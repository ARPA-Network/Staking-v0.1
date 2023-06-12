# ARPA-Network Staking v0.1 Solidity Contracts

## Dependencies

Install [foundry](https://github.com/foundry-rs/foundry#installation).

## Usage

See [interfaces](src/interfaces/) for apis.

```bash
# Install submodule dependencies
forge install
# Compile contracts
# abis can be found in ./out
forge build
# Run Tests
forge test -vv
# Run a specific test
forge test --mt testRewardCalculation1u1n -vvvvv
```

## Coverage

Measure coverage by installing the vscode extension: [coverage gutters](https://marketplace.visualstudio.com/items?itemName=ryanluker.vscode-coverage-gutters)

```bash
forge coverage --report lcov
```

## Local Deployment

### start the local testnet by anvil at localhost:8545:

```bash
# produces a new block every 1 second
anvil --block-time 1
```

### deploy the staking v0.1 contract:

```bash
# use 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 as sender
forge script script/StakingLocalTest.s.sol:StakingLocalTestScript --optimize --fork-url http://localhost:8545 --broadcast
```

### interact with the contarcts by cast:

```bash
# Arpa token address 0x5fbdb2315678afecb367f032d93f642f64180aa3
# Staking address 0xe7f1725e7734ce288f8367e1bb143e90bb3f0512

# address 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# (private key: 0xAC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80)
# will have 1e10 Arpa

# Two nodes have been added into operators whitelist.
# Their private keys and addresses can be found in .env

# to check the Arpa balance
cast call 0x5fbdb2315678afecb367f032d93f642f64180aa3 \
"balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# to mint more Arpa for any address
cast send 0x5fbdb2315678afecb367f032d93f642f64180aa3 \
"mint(address,uint256)" ANY_ADDRESS ANY_AMOUNT \
--private-key 0xAC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80

# to check the owner of deployed staking contract
cast call 0xe7f1725e7734ce288f8367e1bb143e90bb3f0512 "owner()(address)"

# to start the pool with 1,500,000 Arpa reward and 30 days
cast send 0xe7f1725e7734ce288f8367e1bb143e90bb3f0512 "start(uint256,uint256)" 1500000000000000000000000 2592000 \
--private-key 0xAC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80

```

## Acknowledgements

Code structures have been adapted from the following resources:

- [smartcontractkit/staking-v0.1](https://github.com/smartcontractkit/staking-v0.1)
- [Bella-DeFinTech/flex-saving](https://github.com/Bella-DeFinTech/flex-saving)

## Audits and Security

We take security seriously. If you believe you have found a security issue, please report it to us as soon as possible.

We have conducted static analysis on the codebase using [Slither](https://github.com/crytic/slither).

ARPA-Network Staking v0.1 smart contracts have been audited by PeckShield. The audit report is made available [here](audit/PeckShield-Audit-Report-ARPA-v1.0.pdf).
