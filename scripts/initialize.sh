#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🌟 Fusion+ Aptos Contract Initialization${NC}"
echo "====================================="

# Configuration
PACKAGE_ADDRESS="0xdef391b1c8951bf801f67a005f9eba70a5aae6d02eba6bb4889a88288ea806a2"
PROFILE="tokyo"

# Get account address  
ACCOUNT_ADDRESS=$(aptos config show-profiles --profile="$PROFILE" | grep 'account' | sed -n 's/.*"account": "\(.*\)".*/\1/p')

echo -e "${BLUE}🚀 Contract Information${NC}"
echo -e "Account address: ${ACCOUNT_ADDRESS}" 
echo -e "Package address: ${PACKAGE_ADDRESS}"
echo ""

# Function to run a transaction with better error handling
run_transaction() {
    local description=$1
    local cmd="$2"
    
    echo -e "${YELLOW}📤 Initializing: $description${NC}"
    
    eval "$cmd"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ $description initialized successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  $description might already be initialized or failed${NC}"
    fi
    
    echo ""
}

# Initialize custom token
run_transaction "Custom Token" "aptos move run --profile=\"$PROFILE\" --function-id=\"${PACKAGE_ADDRESS}::my_token::initialize\" --args string:'Simple Token' string:'STK' u8:8 bool:true"

# Register for the custom token
run_transaction "Token Registration" "aptos move run --profile=\"$PROFILE\" --function-id=\"0x1::managed_coin::register\" --type-args=\"${PACKAGE_ADDRESS}::my_token::SimpleToken\""

# Initialize escrow factory
run_transaction "Escrow Factory" "aptos move run --profile=\"$PROFILE\" --function-id=\"${PACKAGE_ADDRESS}::escrow_factory::initialize\" --type-args \"0x1::aptos_coin::AptosCoin\" \"${PACKAGE_ADDRESS}::my_token::SimpleToken\" --args u64:3600 u64:7200 address:\"${ACCOUNT_ADDRESS}\" address:\"${ACCOUNT_ADDRESS}\""

# Initialize resolver contract
run_transaction "Resolver Contract" "aptos move run --profile=\"$PROFILE\" --function-id=\"${PACKAGE_ADDRESS}::resolver::initialize\" --args address:\"${PACKAGE_ADDRESS}\""

# Mint some tokens for testing
run_transaction "Token Minting" "aptos move run --profile=\"$PROFILE\" --function-id=\"${PACKAGE_ADDRESS}::my_token::mint\" --args address:\"${ACCOUNT_ADDRESS}\" u64:1000000000000"

# Check current status
echo -e "${BLUE}📊 Checking initialization status...${NC}"
aptos account list --profile "$PROFILE" --query resources | grep -E "(EscrowRegistry|MerkleStorage|FeeBank|EscrowFactory|OrderIntegration|SimpleToken|resolver)" | head -10

echo ""
echo -e "${GREEN}✅ Initialization complete!${NC}"
echo -e "${GREEN}🎉 Your Fusion+ contracts are ready to use.${NC}"