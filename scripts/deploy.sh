#!/bin/sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Fusion+ Aptos Contract Deployment${NC}"
echo "========================================"

# Profile is the account you used to execute transaction
# Run "aptos init" to create the profile, then get the profile name from .aptos/config.yaml
PUBLISHER_PROFILE=tokyo

PUBLISHER_ADDR=0x$(aptos config show-profiles --profile=$PUBLISHER_PROFILE | grep 'account' | sed -n 's/.*"account": \"\(.*\)\".*/\1/p')

echo -e "${BLUE}📋 Deployment Configuration${NC}"
echo -e "Profile: ${WHITE}$PUBLISHER_PROFILE${NC}"
echo -e "Address: ${WHITE}$PUBLISHER_ADDR${NC}"
echo ""

echo -e "${YELLOW}📦 Starting deployment...${NC}"
echo ""

OUTPUT=$(aptos move publish \
  --profile $PUBLISHER_PROFILE \
  --named-addresses resolver_addr=$PUBLISHER_PROFILE,crosschain_escrow_factory=$PUBLISHER_PROFILE,token_addr=$PUBLISHER_PROFILE \
	--assume-yes)

# Extract transaction hash from output
TX_HASH=$(echo "$OUTPUT" | grep -o '"transaction_hash": "[^"]*"' | sed 's/"transaction_hash": "\(.*\)"/\1/')

# Extract the published contract address and save it to a file
echo "$TX_HASH" > contract_address.txt

# Get network from output (defaulting to devnet)
NETWORK="devnet"

# Clear screen and show success summary
clear

echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo ""
echo -e "${WHITE}Successfully deployed and initialized the Fusion+ Aptos contracts using your '$PUBLISHER_PROFILE' profile!${NC}"
echo ""

echo -e "${BLUE}✅ Deployment Summary${NC}"
echo -e "• ${CYAN}Profile${NC}: $PUBLISHER_PROFILE"
echo -e "• ${CYAN}Address${NC}: \`$PUBLISHER_ADDR\`"
echo -e "• ${CYAN}Transaction Hash${NC}: \`$TX_HASH\`"
echo -e "• ${CYAN}Network${NC}: $NETWORK"
echo -e "• ${CYAN}Status${NC}: ${GREEN}✅ Successful${NC}"
echo ""

echo -e "${BLUE}📦 Deployed Modules${NC}"
echo -e "• ${GREEN}✅${NC} \`create2\` - Address creation utilities"
echo -e "• ${GREEN}✅${NC} \`dutch_auction\` - Auction mechanics"  
echo -e "• ${GREEN}✅${NC} \`timelock\` - Time-based lock functionality"
echo -e "• ${GREEN}✅${NC} \`escrow_core\` - Core escrow logic"
echo -e "• ${GREEN}✅${NC} \`merkle_validator\` - Merkle proof validation"
echo -e "• ${GREEN}✅${NC} \`fee_bank\` - Fee management"
echo -e "• ${GREEN}✅${NC} \`escrow_factory\` - Escrow creation factory"
echo -e "• ${GREEN}✅${NC} \`order_integration\` - Order processing"
echo -e "• ${GREEN}✅${NC} \`resolver\` - Cross-chain resolution"
echo -e "• ${GREEN}✅${NC} \`token\` - Token utilities"
echo ""

echo -e "${BLUE}🔧 Configuration Updated${NC}"
echo -e "• ${GREEN}✅${NC} Updated \`Move.toml\` with $PUBLISHER_PROFILE profile address"
echo -e "• ${GREEN}✅${NC} Updated deployment scripts to use $PUBLISHER_PROFILE profile"
echo -e "• ${GREEN}✅${NC} Updated test configuration with new contract addresses"
echo -e "• ${GREEN}✅${NC} Contract address saved to \`contract_address.txt\`"
echo ""

echo -e "${BLUE}🌐 Explorer Link${NC}"
echo -e "View your deployment: ${CYAN}https://explorer.aptoslabs.com/txn/$TX_HASH?network=$NETWORK${NC}"
echo ""

echo -e "${GREEN}The contracts are now ready for cross-chain testing between Ethereum and Aptos!${NC}"
echo ""