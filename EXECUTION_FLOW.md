# Detailed Cross-Chain Atomic Swap Execution Flow

## 🏗️ **System Architecture**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               OFF-CHAIN LAYER                               │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐          │
│  │ Maker (User)    │    │ Relayer/Indexer │    │ Resolver Bots   │          │
│  │ - Creates Order │◄──►│ - Order Book    │◄──►│ - Execute Orders│          │
│  │ - Signs Order   │    │ - Monitoring    │    │ - Profit Seeking│          │
│  │ - Secret Mgmt   │    │ - Coordination  │    │ - Safety Deposits│          │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘          │
│                                  ▲                                          │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                ON-CHAIN LAYER                               │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐          │
│  │ LOP Contract    │    │ Escrow Factory  │    │ Source Escrow   │          │
│  │ - Order Exec    │◄──►│ - Deploy Escrows│◄──►│ - Hold Tokens   │          │
│  │ - Pre/Post Hook │    │ - Validation    │    │ - Time Locks    │          │
│  │ - Amount Calc   │    │ - Events        │    │ - Secret Verify │          │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘          │
│                                                                             │
│                          ┌─────────────────┐    ┌─────────────────┐          │
│                          │ Fee Bank        │    │ Dest Escrow     │          │
│                          │ - Credits       │    │ - Hold Tokens   │          │
│                          │ - Resolver Fees │    │ - Time Locks    │          │
│                          │ - Access Control│    │ - Secret Verify │          │
│                          └─────────────────┘    └─────────────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 📋 **Step-by-Step Execution Flow**

### **Phase 1: Order Creation & Distribution (OFF-CHAIN)**

#### **Step 1: Maker Creates Order**
```typescript
// OFF-CHAIN: Maker prepares order parameters
const orderParams = {
    maker: "0x123...",
    receiver: "0x456...", // Can be different from maker
    makerAsset: "USDC",
    makingAmount: 1000_000000, // 1000 USDC
    takingAmount: 999_000000,  // 999 USDC (accounting for fees)
    dstChainId: 137, // Polygon
    dstToken: "USDC",
    dstAmount: 998_000000, // Amount to receive on Polygon
    secret: generateRandomSecret(),
    safetyDeposits: (0.1 ETH << 64) | 0.1 MATIC, // Combined deposits
    timelocks: createTimelocks(),
    auctionConfig: createAuctionConfig(),
    makerTraits: createMakerTraits(),
    salt: randomSalt()
};

// Create the order structure
const order = order_preparation::create_cross_chain_order(orderParams);
```

#### **Step 2: Maker Signs Order**
```typescript
// OFF-CHAIN: Maker signs the order hash
const orderHash = order_preparation::compute_order_hash(order);
const signature = maker.sign(orderHash); // Using maker's private key

const signedOrder = {
    order,
    signature,
    orderHash
};
```

#### **Step 3: Order Distribution**
```typescript
// OFF-CHAIN: Submit to relayer/indexer
relayer.submitOrder(signedOrder);

// Relayer validates and distributes to resolvers
resolvers.forEach(resolver => {
    if (resolver.interestedInOrder(signedOrder)) {
        resolver.notifyNewOrder(signedOrder);
    }
});
```

### **Phase 2: Resolver Preparation (OFF-CHAIN + ON-CHAIN)**

#### **Step 4: Resolver Evaluates Order**
```typescript
// OFF-CHAIN: Resolver analyzes profitability
const resolver = new Resolver("0x789...");
const profitable = resolver.analyzeProfitability(signedOrder);

if (profitable) {
    // Compute deterministic escrow address
    const srcEscrowAddr = escrow_factory::compute_src_escrow_address(
        factoryAddress,
        createImmutables(signedOrder)
    );
    
    // Send safety deposit to computed address
    await resolver.sendSafetyDeposit(srcEscrowAddr, safetyDepositAmount);
}
```

### **Phase 3: Source Chain Execution (ON-CHAIN)**

#### **Step 5: LOP Pre-Interaction**
```move
// ON-CHAIN: Limit Order Protocol calls pre-interaction
public fun pre_interaction(
    order: OrderData,
    extension: ExtensionData,
    orderHash: vector<u8>,
    taker: address, // Resolver address
    makingAmount: u64,
    takingAmount: u64,
    remainingMakingAmount: u64,
    extraData: vector<u8>
) {
    // Validate order parameters
    // Check auction pricing
    // Emit pre-interaction event
    // Prepare for token transfer
}
```

#### **Step 6: Token Transfer**
```move
// ON-CHAIN: LOP transfers maker's tokens to computed escrow address
// This happens automatically as part of the limit order execution
// Tokens are sent to the deterministic address computed earlier
```

#### **Step 7: LOP Post-Interaction (Source Escrow Creation)**
```move
// ON-CHAIN: Create source escrow after token transfer
public fun post_interaction(
    order: OrderData,
    extension: ExtensionData,
    orderHash: vector<u8>,
    taker: address,
    makingAmount: u64,
    takingAmount: u64,
    remainingMakingAmount: u64,
    extraData: vector<u8>
) {
    // Parse escrow creation arguments from extraData
    let args = parse_extra_data_to_src_args(extraData);
    
    // Validate resolver access and charge fees
    fee_bank::validate_resolver_access(whitelist, taker, accessTokenConfig, feeConfig);
    
    // Create source escrow
    let escrowAddr = escrow_factory::create_src_escrow(
        factory_address,
        order,
        taker,
        makingAmount,
        takingAmount,
        remainingMakingAmount,
        args
    );
    
    // Emit event with destination chain parameters
    emit SrcEscrowCreatedEvent {
        escrow_address: escrowAddr,
        immutables,
        dst_complement,
        timestamp
    };
}
```

### **Phase 4: Destination Chain Execution (ON-CHAIN)**

#### **Step 8: Resolver Monitors & Creates Destination Escrow**
```move
// OFF-CHAIN: Resolver detects source escrow creation event
resolver.onSourceEscrowCreated(event => {
    // Validate event parameters match expected order
    // Prepare destination escrow parameters
});

// ON-CHAIN: Resolver calls destination escrow creation
public entry fun create_dst_escrow(
    resolver: &signer,
    factory_addr: address,
    tokens: Coin<USDC>, // Resolver's tokens for the user
    safety_deposit: Coin<AptosCoin>,
    args: DstEscrowArgs
) {
    // Validate amounts and timing
    // Create destination escrow
    let escrowAddr = escrow_factory::create_dst_escrow(
        resolver,
        factory_addr,
        tokens,
        safety_deposit,
        args
    );
    
    // Emit creation event
    emit DstEscrowCreatedEvent {
        escrow_address: escrowAddr,
        hashlock,
        taker,
        timestamp
    };
}
```

### **Phase 5: Secret Distribution (OFF-CHAIN)**

#### **Step 9: Verification & Secret Distribution**
```typescript
// OFF-CHAIN: Relayer verifies both escrows exist
const srcEscrowExists = await verifyEscrowDeployment(srcChain, srcEscrowAddr);
const dstEscrowExists = await verifyEscrowDeployment(dstChain, dstEscrowAddr);

if (srcEscrowExists && dstEscrowExists) {
    // Validate parameters match
    const parametersMatch = validateCrossChainParameters(srcEscrow, dstEscrow);
    
    if (parametersMatch) {
        // Distribute secret to resolver
        await distributeSecret(resolver, originalSecret);
    }
}
```

### **Phase 6: Token Withdrawal (ON-CHAIN)**

#### **Step 10: Destination Chain Withdrawal (User receives tokens)**
```move
// ON-CHAIN: Resolver (or any resolver with access token) withdraws to user
public entry fun withdraw_to_user(
    caller: &signer,
    escrow_addr: address,
    secret: vector<u8>,
    immutables: EscrowImmutables
) {
    // Validate secret matches hashlock
    assert!(validate_secret(secret, immutables.hashlock));
    
    // Validate timing (private or public withdrawal period)
    timelock::assert_in_window(
        &immutables.timelocks,
        timelock::stage_dst_withdrawal(),
        timelock::stage_dst_cancellation()
    );
    
    // Transfer tokens to user (maker or receiver)
    let tokens = coin::extract_all(&mut escrow.locked_tokens);
    coin::deposit(immutables.maker, tokens);
    
    // Transfer safety deposit to caller (incentive)
    let deposit = coin::extract_all(&mut escrow.safety_deposit);
    coin::deposit(caller_addr, deposit);
    
    emit EscrowWithdrawalEvent { secret, recipient: immutables.maker, ... };
}
```

#### **Step 11: Source Chain Withdrawal (Resolver receives tokens)**
```move
// ON-CHAIN: Resolver withdraws their earned tokens
public entry fun withdraw_to_resolver(
    caller: &signer,
    escrow_addr: address,
    secret: vector<u8>,
    resolver_addr: address,
    immutables: EscrowImmutables
) {
    // Same secret validation
    // Same timing validation
    
    // Transfer tokens to resolver
    let tokens = coin::extract_all(&mut escrow.locked_tokens);
    coin::deposit(resolver_addr, tokens);
    
    // Transfer safety deposit to caller
    let deposit = coin::extract_all(&mut escrow.safety_deposit);
    coin::deposit(caller_addr, deposit);
    
    emit EscrowWithdrawalEvent { secret, recipient: resolver_addr, ... };
}
```

## 🔄 **Alternative Flows**

### **Cancellation Flow (if secret not distributed)**

```move
// ON-CHAIN: Cancel escrows if secret not revealed in time
public entry fun cancel_src_escrow(
    caller: &signer,
    escrow_addr: address,
    immutables: EscrowImmutables
) {
    // Must be in cancellation period
    timelock::assert_after_stage(&immutables.timelocks, timelock::stage_src_cancellation());
    
    // Return tokens to maker (user)
    let tokens = coin::extract_all(&mut escrow.locked_tokens);
    coin::deposit(immutables.maker, tokens);
    
    // Safety deposit to caller (incentive for cleanup)
    let deposit = coin::extract_all(&mut escrow.safety_deposit);
    coin::deposit(caller_addr, deposit);
}

public entry fun cancel_dst_escrow(
    caller: &signer,
    escrow_addr: address,
    immutables: EscrowImmutables
) {
    // Similar logic but returns tokens to resolver (taker)
    let tokens = coin::extract_all(&mut escrow.locked_tokens);
    coin::deposit(immutables.taker, tokens);
}
```

### **Partial Fill Flow (with Merkle Proofs)**

```move
// For orders that allow partial fills
public entry fun partial_fill_with_proof(
    order: OrderData,
    merkle_proof: vector<vector<u8>>,
    secret_index: u64,
    secret: vector<u8>,
    fill_amount: u64
) {
    // Validate merkle proof
    let config = merkle_validator::new_multiple_fill_config(order.merkle_root, order.parts_count);
    let taker_data = merkle_validator::new_taker_data(merkle_proof, secret_index, hash::sha3_256(secret));
    
    merkle_validator::validate_and_store_proof(validator, order.hash, &config, &taker_data);
    
    // Validate fill amount corresponds to secret index
    assert!(merkle_validator::is_valid_partial_fill(
        fill_amount,
        remaining_amount,
        order.making_amount,
        order.parts_count,
        secret_index + 1
    ));
    
    // Create escrows with the validated secret hash
    // ... rest of escrow creation logic
}
```

## 📊 **Key Insights from This Flow**

### **What is ON-CHAIN:**
- ✅ LOP contract execution
- ✅ Escrow creation and deployment
- ✅ Token transfers and locks
- ✅ Secret validation and withdrawals
- ✅ Time-based access control
- ✅ Fee charging and credit management
- ✅ Cancellation and rescue operations

### **What is OFF-CHAIN:**
- ✅ Order creation and signing
- ✅ Order distribution and indexing
- ✅ Resolver discovery and notification
- ✅ Cross-chain monitoring and coordination
- ✅ Secret distribution after validation
- ✅ Profitability analysis
- ✅ Event monitoring and automation

### **What the Maker Signs:**
- ✅ **Structured order object** (not a function)
- ✅ Contains all swap parameters
- ✅ Includes cross-chain details
- ✅ Standard EIP-712 style signing

### **Resolver Economics:**
- ✅ Must deposit safety deposits upfront
- ✅ Earns trading fees/spread
- ✅ Gets safety deposit back on successful execution
- ✅ Can lose safety deposit if they don't execute properly
- ✅ Incentivized to execute quickly and correctly

## 🔐 **Security & Trust Model**

### **Trust Assumptions:**
1. **Relayer Trust**: Off-chain relayer is trusted for coordination but cannot steal funds
2. **Secret Distribution**: Off-chain mechanism securely distributes secrets only when both escrows are valid
3. **Time Safety**: Sufficient time gaps between stages to handle cross-chain delays
4. **Economic Security**: Safety deposits are large enough to incentivize honest behavior

### **Attack Vectors & Mitigations:**

#### **Resolver Griefing:**
- **Attack**: Resolver creates source escrow but not destination escrow
- **Mitigation**: Safety deposits lost if escrow is cancelled, time-based public access

#### **Front-running:**
- **Attack**: MEV bot tries to extract value from order
- **Mitigation**: Resolver whitelisting, access token requirements, time-based access

#### **Cross-chain Timing:**
- **Attack**: Blockchain reorganizations cause timing issues
- **Mitigation**: Conservative timelock settings, finality requirements

#### **Secret Theft:**
- **Attack**: Secret intercepted and used by another party
- **Mitigation**: Access token requirements for public withdrawals, economic incentives

## 🧪 **Example Complete Flow**

Let's trace through a complete example:

### **Setup:**
- **User**: Wants to swap 1000 USDC on Ethereum → 950 USDC on Polygon
- **Resolver**: Bot looking for arbitrage opportunities
- **Secret**: `0x1234...` (32 bytes)
- **Safety Deposits**: 0.1 ETH on source, 100 MATIC on destination

### **Execution:**

```typescript
// 1. OFF-CHAIN: User creates order
const order = {
    maker: "0xUserAddress",
    makerAsset: "USDC",
    makingAmount: 1000_000000,
    dstChainId: 137,
    dstToken: "USDC", 
    dstAmount: 950_000000,
    secret: "0x1234...",
    // ... other params
};

// 2. OFF-CHAIN: User signs order
const signature = user.sign(orderHash);

// 3. OFF-CHAIN: Relayer distributes to resolvers
relayer.broadcast(signedOrder);

// 4. OFF-CHAIN: Resolver decides to fill
const resolver = resolvers.find(r => r.wantsTofill(signedOrder));

// 5. ON-CHAIN: Resolver sends safety deposit to computed address
const srcEscrowAddr = computeAddress(order);
await resolver.sendEth(srcEscrowAddr, 0.1); // ETH

// 6. ON-CHAIN: Resolver fills order on Ethereum
await lop.fillOrder(signedOrder, resolverSignature, extraData);
// This triggers:
//   - pre_interaction()
//   - token transfer (1000 USDC to escrow)
//   - post_interaction() -> creates source escrow

// 7. ON-CHAIN: Resolver creates destination escrow on Polygon
await polygonFactory.createDstEscrow(
    dstImmutables,
    srcCancellationTimestamp,
    {value: 100} // MATIC safety deposit
);
// Resolver also deposits 950 USDC for the user

// 8. OFF-CHAIN: Relayer verifies both escrows and distributes secret
if (bothEscrowsValid(srcEscrow, dstEscrow)) {
    relayer.distributeSecret(resolver, "0x1234...");
}

// 9. ON-CHAIN: Resolver withdraws user tokens on Polygon
await dstEscrow.withdraw(
    "0x1234...", // secret
    dstImmutables,
    userAddress
);
// User receives 950 USDC + resolver gets 100 MATIC safety deposit

// 10. ON-CHAIN: Resolver withdraws their tokens on Ethereum
await srcEscrow.withdraw(
    "0x1234...", // secret
    srcImmutables,
    resolverAddress
);
// Resolver receives 1000 USDC + 0.1 ETH safety deposit

// 11. PROFIT: Resolver made 50 USDC profit (minus gas costs)
```

## 🎯 **Key Design Decisions Explained**

### **Why Sign Order Structure (Not Function):**
- ✅ **Flexibility**: Order can be filled by any compatible resolver
- ✅ **Standardization**: EIP-712 compatible signing
- ✅ **Off-chain Distribution**: Orders can be shared and indexed
- ✅ **Replay Protection**: Nonce and expiration built-in

### **Why LOP is On-Chain:**
- ✅ **Trust Minimization**: No reliance on off-chain execution
- ✅ **Atomic Execution**: Order fill + escrow creation in one transaction
- ✅ **Standardization**: Compatible with existing limit order infrastructure
- ✅ **Composability**: Can integrate with other DeFi protocols

### **Why Off-Chain Coordination:**
- ✅ **Cross-Chain**: No native cross-chain messaging needed
- ✅ **Efficiency**: Reduces on-chain complexity and costs
- ✅ **Flexibility**: Can adapt to different chains and requirements
- ✅ **Scalability**: Supports high-frequency trading

### **Why Safety Deposits:**
- ✅ **Incentive Alignment**: Ensures resolvers complete swaps
- ✅ **Griefing Protection**: Economic cost for malicious behavior
- ✅ **Execution Rewards**: Compensates honest executors
- ✅ **Decentralization**: Anyone can become a resolver with deposit

## 🚀 **Benefits of This Architecture**

### **For Users:**
- ✅ **No Bridge Risk**: Funds never leave escrow until swap completes
- ✅ **Competitive Pricing**: Dutch auction mechanism
- ✅ **Fast Execution**: Resolver competition drives speed
- ✅ **Partial Fills**: Large orders can be filled incrementally

### **For Resolvers:**
- ✅ **Profit Opportunities**: Earn fees and spreads
- ✅ **Fair Competition**: Time-based access prevents MEV
- ✅ **Risk Management**: Clear time windows and escape hatches
- ✅ **Scalability**: Can run multiple swaps simultaneously

### **For the Ecosystem:**
- ✅ **Decentralized**: No central authority or bridge operator
- ✅ **Trustless**: Cryptographic and economic security
- ✅ **Composable**: Integrates with existing DeFi infrastructure
- ✅ **Efficient**: Minimal cross-chain messaging overhead

## 📋 **Summary**

This architecture successfully separates concerns:

- **ON-CHAIN**: Handles money, security, and enforcement
- **OFF-CHAIN**: Handles coordination, discovery, and optimization
- **HYBRID**: Secret distribution bridges both worlds securely

The key insight is that while the coordination is off-chain, all the critical security properties (fund safety, atomic execution, time guarantees) are enforced on-chain through smart contracts and economic incentives.