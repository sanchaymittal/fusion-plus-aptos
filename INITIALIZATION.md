# Fusion+ Aptos Contract Initialization Guide

## Overview
After deploying your Fusion+ contracts, you need to initialize several modules in the correct order. This guide provides scripts and instructions to do so.

## Prerequisites
- Contracts successfully deployed
- Aptos CLI installed and configured
- Your account has sufficient APT for transaction fees

## Quick Start (Bash Script)

1. **Update the configuration** in `scripts/initialize.sh`:
   ```bash
   # Update this with your deployed package address
   PACKAGE_ADDRESS="your-actual-package-address-here"
   
   # Update profile if needed
   PROFILE="default"
   ```

2. **Run the initialization script**:
   ```bash
   ./scripts/initialize.sh
   ```

## Manual Initialization Steps

If you prefer to run each step manually:

### Step 1: Initialize Custom Token
```bash
# Initialize your custom token contract
aptos move run \
  --function-id "PACKAGE_ADDRESS::my_token::initialize" \
  --args "string:\"Fusion Test Token\" string:\"FTT\" u8:8 bool:true" \
  --profile default

# Mint some tokens for testing
aptos move run \
  --function-id "PACKAGE_ADDRESS::my_token::mint" \
  --args "address:YOUR_ADDRESS u64:1000000000" \
  --profile default
```

### Step 2: Basic Modules
```bash
# Initialize escrow core
aptos move run --function-id "PACKAGE_ADDRESS::escrow_core::initialize" --profile default

# Initialize merkle validator  
aptos move run --function-id "PACKAGE_ADDRESS::merkle_validator::initialize" --profile default
```

### Step 3: Fee Bank Modules
```bash
# Initialize fee bank (using custom SimpleToken)
aptos move run \
  --function-id "PACKAGE_ADDRESS::fee_bank::initialize_fee_bank" \
  --type-args "PACKAGE_ADDRESS::my_token::SimpleToken" \
  --profile default

# Initialize access token config (using SimpleToken, requiring 1M tokens minimum)
aptos move run \
  --function-id "PACKAGE_ADDRESS::fee_bank::initialize_access_token" \
  --type-args "PACKAGE_ADDRESS::my_token::SimpleToken" \
  --args "u64:1000000" \
  --profile default
```

### Step 4: Escrow Factory
```bash
# Get your account address first
ACCOUNT=$(aptos account list --profile default --query balance | head -1 | cut -d' ' -f1)

# Initialize escrow factory
aptos move run \
  --function-id "PACKAGE_ADDRESS::escrow_factory::initialize" \
  --type-args "PACKAGE_ADDRESS::my_token::SimpleToken PACKAGE_ADDRESS::my_token::SimpleToken" \
  --args "u64:86400 u64:86400 address:$ACCOUNT address:$ACCOUNT" \
  --profile default
```

### Step 5: Order Integration
```bash
# Initialize order integration
aptos move run \
  --function-id "PACKAGE_ADDRESS::order_integration::initialize" \
  --type-args "PACKAGE_ADDRESS::my_token::SimpleToken PACKAGE_ADDRESS::my_token::SimpleToken" \
  --args "address:0x1 address:$ACCOUNT" \
  --profile default
```

## Configuration Parameters

### Rescue Delays
- `SRC_RESCUE_DELAY`: 86400 seconds (24 hours) - time before source chain rescue is allowed
- `DST_RESCUE_DELAY`: 86400 seconds (24 hours) - time before destination chain rescue is allowed

### Token Types
- `FEE_TOKEN_TYPE`: "PACKAGE_ADDRESS::my_token::SimpleToken" - custom token used for fees
- `ACCESS_TOKEN_TYPE`: "PACKAGE_ADDRESS::my_token::SimpleToken" - custom token required for access

### Access Requirements
- `MIN_ACCESS_TOKEN_BALANCE`: 1000000 tokens - minimum balance required

### Addresses
- `fee_bank_owner`: Your account address - who owns the fee bank
- `access_token_config_addr`: Your account address - where access config is stored
- `limit_order_protocol`: Replace "0x1" with actual protocol address
- `factory_address`: Your account address - where the factory is deployed

## Verification

After initialization, check that all resources are created:

```bash
aptos account list --profile default --query resources | grep -E "(EscrowRegistry|MerkleStorage|FeeBank|EscrowFactory|OrderIntegration)"
```

You should see resources like:
- `EscrowRegistry`
- `MerkleStorage` 
- `FeeBank<AptosCoin>`
- `EscrowFactory<AptosCoin, AptosCoin>`
- `OrderIntegration<AptosCoin, AptosCoin>`

## Troubleshooting

### "Already Exists" Errors
If you see errors about resources already existing, that's normal - it means those modules are already initialized.

### Transaction Failures
- Ensure you have sufficient APT for gas fees
- Double-check the package address is correct
- Verify your account has the necessary permissions

### Missing Dependencies
If initialization fails, ensure you've run the steps in order, as some modules depend on others.

## TypeScript Version

For programmatic initialization, see `scripts/initialize.ts`. Update the configuration values and run:

```bash
npm install aptos
npx ts-node scripts/initialize.ts
```

## Next Steps

After successful initialization, your contracts are ready to use! You can now:
- Create escrows
- Process orders
- Manage fees
- Validate merkle proofs

Refer to the main documentation for usage examples and API details.