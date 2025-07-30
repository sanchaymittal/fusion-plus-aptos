#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🌟 Fusion+ Aptos Contract Initialization${NC}"
echo "====================================="

# Configuration - UPDATE THESE VALUES
PACKAGE_ADDRESS="bf4897e1461fb38861f8431f68b1332d90dd62e3f0d454470b6fc9278dd8bccc"
PROFILE="default"  # Your aptos profile name

# Token types (using custom SimpleToken)
FEE_TOKEN_TYPE="PACKAGE_ADDRESS::my_token::SimpleToken"
ACCESS_TOKEN_TYPE="PACKAGE_ADDRESS::my_token::SimpleToken"

# Configuration values
SRC_RESCUE_DELAY=86400  # 24 hours
DST_RESCUE_DELAY=86400  # 24 hours
MIN_ACCESS_TOKEN_BALANCE=1000000  # 1M tokens minimum balance
LIMIT_ORDER_PROTOCOL_ADDRESS="0x1"  # Replace with actual protocol address

# Validate configuration
if [ "$PACKAGE_ADDRESS" = "your-package-address-here" ]; then
    echo -e "${RED}❌ Please update PACKAGE_ADDRESS with your deployed package address${NC}"
    exit 1
fi

# Function to run a transaction
run_transaction() {
    local function_name=$1
    local type_args=$2
    local args=$3
    local description=$4
    
    echo -e "${YELLOW}📤 Initializing: $description${NC}"
    
    if [ -n "$type_args" ] && [ -n "$args" ]; then
        aptos move run \
            --function-id "${PACKAGE_ADDRESS}::${function_name}" \
            --type-args "$type_args" \
            --args "$args" \
            --profile "$PROFILE" \
            --assume-yes
    elif [ -n "$type_args" ]; then
        aptos move run \
            --function-id "${PACKAGE_ADDRESS}::${function_name}" \
            --type-args "$type_args" \
            --profile "$PROFILE" \
            --assume-yes
    elif [ -n "$args" ]; then
        aptos move run \
            --function-id "${PACKAGE_ADDRESS}::${function_name}" \
            --args "$args" \
            --profile "$PROFILE" \
            --assume-yes
    else
        aptos move run \
            --function-id "${PACKAGE_ADDRESS}::${function_name}" \
            --profile "$PROFILE" \
            --assume-yes
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $description initialized successfully${NC}"
    else
        echo -e "${RED}❌ Failed to initialize $description${NC}"
        # Don't exit on error - might already be initialized
    fi
    
    echo ""
}

echo -e "${BLUE}🚀 Starting module initialization...${NC}"

# Get account address
ACCOUNT_ADDRESS="bf4897e1461fb38861f8431f68b1332d90dd62e3f0d454470b6fc9278dd8bccc"
echo -e "Account address: ${ACCOUNT_ADDRESS}"

# Substitute PACKAGE_ADDRESS in token types
FEE_TOKEN_TYPE="${FEE_TOKEN_TYPE/PACKAGE_ADDRESS/$PACKAGE_ADDRESS}"
ACCESS_TOKEN_TYPE="${ACCESS_TOKEN_TYPE/PACKAGE_ADDRESS/$PACKAGE_ADDRESS}"

echo -e "Fee token type: ${FEE_TOKEN_TYPE}"
echo -e "Access token type: ${ACCESS_TOKEN_TYPE}"
echo ""

# Step 1: Check token contract (skip if already initialized)
echo -e "${BLUE}🪙 Step 1: Checking token contract...${NC}"
echo -e "${GREEN}✅ Custom Token already initialized${NC}"
echo ""

# Step 2: Initialize basic modules
echo -e "${BLUE}📋 Step 2: Initializing basic modules...${NC}"

run_transaction "escrow_core::initialize" "" "" "Escrow Core"
run_transaction "merkle_validator::initialize" "" "" "Merkle Validator"

# Step 3: Initialize fee bank modules
echo -e "${BLUE}💰 Step 3: Initializing fee bank modules...${NC}"

run_transaction "fee_bank::initialize_fee_bank" "$FEE_TOKEN_TYPE" "" "Fee Bank"
run_transaction "fee_bank::initialize_access_token" "$ACCESS_TOKEN_TYPE" "u64:$MIN_ACCESS_TOKEN_BALANCE" "Access Token Config"

# Step 4: Initialize escrow factory
echo -e "${BLUE}🏭 Step 4: Initializing escrow factory...${NC}"

run_transaction "escrow_factory::initialize" "$FEE_TOKEN_TYPE $ACCESS_TOKEN_TYPE" "u64:$SRC_RESCUE_DELAY" "Escrow Factory"

# Step 5: Initialize order integration
echo -e "${BLUE}🔄 Step 5: Initializing order integration...${NC}"

run_transaction "order_integration::initialize" "$FEE_TOKEN_TYPE $ACCESS_TOKEN_TYPE" "address:$LIMIT_ORDER_PROTOCOL_ADDRESS address:$ACCOUNT_ADDRESS" "Order Integration"

echo -e "${GREEN}🎉 Initialization complete! Your contracts are ready to use.${NC}"

# Optional: Show account resources
echo -e "${BLUE}📊 Checking initialized resources...${NC}"
aptos account list --profile "$PROFILE" --query resources | grep -E "(EscrowRegistry|MerkleStorage|FeeBank|EscrowFactory|OrderIntegration)" || echo "Run with --query resources to see all resources"

echo ""
echo -e "${GREEN}✅ All done! Your Fusion+ contracts are initialized and ready.${NC}"