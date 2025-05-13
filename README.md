## Documentation

[check here](NOTES.md)

## Usage

### Clone

```shell
git clone --recurse-submodules git@github.com:azubr/DynamicStakingVault.git
```

### Open

VSCode devcontainer with Foundry is provided. Use ``Dev Containers: Reopen in container`` command.


### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploy

```shell
$ forge script DynamicStakingVaultScript <token_address> <token_decimals> --sig "run(address,uint)" --chain <chain_name> --interactives 1 --rpc-url <rpc_url> --broadcast --verify -vvvv
```

example:
```shell
$ source .env
$ forge script DynamicStakingVaultScript 0x1c7d4b196cb0c7b01d743fbc6116a902379c7238 6 --sig "run(address,uint)" --chain sepolia --interactives 1 --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

### Query

```shell
cast call --rpc-url <rpc_url> <vault_address> <signature> <params>
```

example:
```shell
source .env
cast call --rpc-url $SEPOLIA_RPC_URL 0xd4e486E635DE6E2C195bAcb9FcC802e056190Cc7 "lockedAmount(address,uint256)(uint256)" 0x150eF8C701565cf824c3cF0f6372F06E101B2Abd 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
```

### Submit transactions

```shell
cast send --rpc-url <rpc_url> --interactive <vault_address> <signature> <params>
```

example:
```shell
source .env
cast send --rpc-url $SEPOLIA_RPC_URL --interactive 0xd4e486E635DE6E2C195bAcb9FcC802e056190Cc7 "approve(address,uint256)" 0x1c7d4b196cb0c7b01d743fbc6116a902379c7238 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
```


