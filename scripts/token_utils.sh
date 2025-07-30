#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🪙 Fusion+ Token Utilities${NC}"
echo "========================="

# Configuration - UPDATE THESE VALUES
PACKAGE_ADDRESS="your-package-address-here"
PROFILE="default"

# Validate configuration
if [ "$PACKAGE_ADDRESS" = "your-package-address-here" ]; then
    echo -e "${RED}❌ Please update PACKAGE_ADDRESS with your deployed package address${NC}"
    exit 1
fi

# Get account address
ACCOUNT_ADDRESS=$(aptos account list --profile "$PROFILE" --query balance | head -1 | cut -d' ' -f1)
TOKEN_TYPE="${PACKAGE_ADDRESS}::my_token::SimpleToken"

echo -e "Account address: ${ACCOUNT_ADDRESS}"
echo -e "Token type: ${TOKEN_TYPE}"
echo ""

# Function to run a transaction
run_transaction() {
    local function_name=$1
    local args=$2
    local description=$3
    
    echo -e "${YELLOW}📤 ${description}${NC}"
    
    if [ -n "$args" ]; then
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
        echo -e "${GREEN}✅ ${description} completed successfully${NC}"
    else
        echo -e "${RED}❌ Failed: ${description}${NC}"
    fi
    echo ""
}

# Function to check token balance
check_balance() {
    local address=${1:-$ACCOUNT_ADDRESS}
    echo -e "${BLUE}💰 Checking token balance for: ${address}${NC}"
    
    aptos account list --profile "$PROFILE" --query resources --account-address "$address" | grep -A5 -B5 "SimpleToken" || echo "No SimpleToken found"
    echo ""
}

# Menu system
show_menu() {
    echo -e "${BLUE}Available Operations:${NC}"
    echo "1. Check token balance"
    echo "2. Mint tokens to your account"
    echo "3. Mint tokens to another address"
    echo "4. Transfer tokens"
    echo "5. Burn tokens"
    echo "6. Check all account resources"
    echo "7. Exit"
    echo ""
}

# Main loop
while true; do
    show_menu
    read -p "Select an option (1-7): " choice
    echo ""
    
    case $choice in
        1)
            check_balance
            ;;
        2)
            read -p "Enter amount to mint: " amount
            run_transaction "my_token::mint" "address:$ACCOUNT_ADDRESS u64:$amount" "Minting $amount tokens to your account"
            check_balance
            ;;
        3)
            read -p "Enter recipient address: " recipient
            read -p "Enter amount to mint: " amount
            run_transaction "my_token::mint" "address:$recipient u64:$amount" "Minting $amount tokens to $recipient"
            ;;
        4)
            read -p "Enter recipient address: " recipient
            read -p "Enter amount to transfer: " amount
            run_transaction "my_token::transfer" "address:$recipient u64:$amount" "Transferring $amount tokens to $recipient"
            check_balance
            ;;
        5)
            read -p "Enter amount to burn: " amount
            run_transaction "my_token::burn" "u64:$amount" "Burning $amount tokens"
            check_balance
            ;;
        6)
            echo -e "${BLUE}📊 All account resources:${NC}"
            aptos account list --profile "$PROFILE" --query resources
            echo ""
            ;;
        7)
            echo -e "${GREEN}👋 Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Invalid option. Please choose 1-7.${NC}"
            echo ""
            ;;
    esac
done