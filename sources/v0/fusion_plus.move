module fusion_plus_addr::fusion_plus {
    use std::signer;
    use std::vector;
    use std::bcs;
    use std::aptos_hash;
    use aptos_std::string::{Self, String};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::type_info::{Self, TypeInfo};
    use aptos_framework::table::{Self, Table};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_std::type_info as std_type_info;
    use aptos_framework::event;

    /// Error constants
    const ESWAP_LEDGER_ALREADY_EXISTS: u64 = 1;
    const ESWAP_LEDGER_DOES_NOT_EXIST: u64 = 2;
    const EINVALID_AMOUNT: u64 = 3;
    const EORDER_DOES_NOT_EXIST: u64 = 4;
    const EORDER_ALREADY_FILLED_OR_CANCELLED: u64 = 5;
    const EORDER_EXPIRED: u64 = 6;
    const EORDER_NOT_EXPIRED: u64 = 7;
    const EINVALID_MAKER: u64 = 8;
    const EINSUFFICIENT_AMOUNT: u64 = 9;
    const EINVALID_COIN_TYPE: u64 = 10;
    const EINVALID_SECRET: u64 = 11;
    const EESCROWS_NOT_FUNDED: u64 = 12;
    const EINVALID_RESOLVER: u64 = 13;
    const ESECRET_ALREADY_REVEALED: u64 = 14;
    const EINVALID_SECRET_HASH: u64 = 15;
    const EORDER_NOT_DEPOSITED: u64 = 16;
    const ENOT_MAKER: u64 = 17;
    const EBAD_STATE: u64 = 18;
    const EINVALID_TIME: u64 = 19;
    const EINVALID_TIMELOCK: u64 = 20;

    /// Timelock stage constants for cross-chain coordination
    const STAGE_SRC_WITHDRAWAL: u8 = 0;         // When resolver can claim source funds
    const STAGE_SRC_PUBLIC_WITHDRAWAL: u8 = 1;  // When anyone can claim with secret
    const STAGE_SRC_CANCELLATION: u8 = 2;       // When maker can cancel and reclaim funds
    const STAGE_SRC_PUBLIC_CANCELLATION: u8 = 3;// When anyone can cancel for maker
    const STAGE_DST_WITHDRAWAL: u8 = 4;         // When maker can claim destination funds
    const STAGE_DST_PUBLIC_WITHDRAWAL: u8 = 5;  // When anyone can claim dst with secret
    const STAGE_DST_CANCELLATION: u8 = 6;       // When resolver can cancel and reclaim funds

    /// Constants for timelock bit manipulation (EVM compatibility)
    const DEPLOYED_AT_MASK: u256 = 0xffffffff00000000000000000000000000000000000000000000000000000000;
    const DEPLOYED_AT_OFFSET: u8 = 224;
    
    /// All bits set for bitwise NOT operations
    const ALL_BITS: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// Timelock structure for compact storage compatible with EVM chains
    /// Uses same bit-packing pattern as Solidity implementation for cross-chain consistency
    struct Timelocks has store, copy, drop {
        /// Packed timelocks data containing deployment timestamp and stage durations
        /// Bits 255-224: deployed_at timestamp (32 bits)
        /// Bits 223-192: dst_cancellation_offset (32 bits) 
        /// Bits 191-160: dst_public_withdrawal_offset (32 bits)
        /// Bits 159-128: dst_withdrawal_offset (32 bits)
        /// Bits 127-96:  src_public_cancellation_offset (32 bits)
        /// Bits 95-64:   src_cancellation_offset (32 bits)
        /// Bits 63-32:   src_public_withdrawal_offset (32 bits)
        /// Bits 31-0:    src_withdrawal_offset (32 bits)
        data: u256,
    }

    /// Original explicit timelock structure (for reference and conversion)
    struct ExplicitTimelocks has store, copy, drop {
        // Timestamp when the order was created
        deployed_at: u64,
        // Time after deployment when withdrawal is allowed
        src_withdrawal_offset: u64,
        // Time after deployment when public withdrawal is allowed
        src_public_withdrawal_offset: u64,
        // Time after deployment when cancellation is allowed
        src_cancellation_offset: u64,
        // Time after deployment when public cancellation is allowed
        src_public_cancellation_offset: u64,
        // Time after deployment when destination withdrawal is allowed
        dst_withdrawal_offset: u64,
        // Time after deployment when destination public withdrawal is allowed
        dst_public_withdrawal_offset: u64,
        // Time after deployment when destination cancellation is allowed
        dst_cancellation_offset: u64,
    }

    /// Resource struct representing individual swap order metadata
    /// Each order represents one side of a cross-chain atomic swap
    struct OrderMetadata has store, drop {
        id: u64,                        // Unique order ID on this chain
        maker_address: address,         // Address of the order creator (maker or resolver)
        escrow_address: address,        // Escrow holding the deposited funds
        escrow_cap: SignerCapability,   // Capability to control escrow account
        coin_type: TypeInfo,            // Type of coin being escrowed
        amount: u64,                    // Amount of coins escrowed
        min_amount: u64,                // Minimum amount expected from other chain
        timelocks: Timelocks,           // Time-based constraints for the swap
        secret_hash: vector<u8>,        // Keccak256 hash of the secret (links orders across chains)
        resolver_address: address,      // Address of resolver (for dst orders) or @0x0 (for src orders)
        revealed_secret: vector<u8>,    // The actual secret (empty until revealed)
    }

    /// Resource struct for the swap ledger
    struct SwapLedger has key {
        orders: Table<u64, OrderMetadata>,  // All orders on this chain
        order_id_counter: u64,              // Counter for generating unique order IDs
        signer_cap: SignerCapability,       // Capability for creating escrow accounts
    }

    /// Events for tracking swap operations
    #[event]
    struct OrderCreated has drop, store {
        order_id: u64,
        maker: address,
        escrow_address: address,
        amount: u64,
        min_amount: u64,
        secret_hash: vector<u8>,
        timestamp: u64,
    }

    #[event]
    struct OrderFilled has drop, store {
        order_id: u64,
        resolver: address,
        secret: vector<u8>,
        timestamp: u64,
    }

    #[event]
    struct OrderCancelled has drop, store {
        order_id: u64,
        maker: address,
        timestamp: u64,
    }

    /// Helper function to get the ledger address consistently
    fun get_ledger_address(): address {
        let seed = b"fusion_plus_addr";
        account::create_resource_address(&@fusion_plus_addr, seed)
    }

    /// Convert from explicit timelock format to compact format
    /// Packs all timelock data into a single u256 for EVM compatibility
    fun convert_to_compact_timelocks(
        deployed_at: u64,
        src_withdrawal_offset: u64,
        src_public_withdrawal_offset: u64,
        src_cancellation_offset: u64,
        src_public_cancellation_offset: u64,
        dst_withdrawal_offset: u64,
        dst_public_withdrawal_offset: u64,
        dst_cancellation_offset: u64
    ): Timelocks {
        // Start with empty data
        let data: u256 = 0;
        
        // Set deployed_at in the highest 32 bits
        data = data | ((deployed_at as u256) << DEPLOYED_AT_OFFSET);
        
        // Set each offset in its respective 32-bit slot
        // Each stage uses 32 bits, with stage 0 at the lowest bits
        data = data | ((src_withdrawal_offset as u256) << (STAGE_SRC_WITHDRAWAL * 32));
        data = data | ((src_public_withdrawal_offset as u256) << (STAGE_SRC_PUBLIC_WITHDRAWAL * 32));
        data = data | ((src_cancellation_offset as u256) << (STAGE_SRC_CANCELLATION * 32));
        data = data | ((src_public_cancellation_offset as u256) << (STAGE_SRC_PUBLIC_CANCELLATION * 32));
        data = data | ((dst_withdrawal_offset as u256) << (STAGE_DST_WITHDRAWAL * 32));
        data = data | ((dst_public_withdrawal_offset as u256) << (STAGE_DST_PUBLIC_WITHDRAWAL * 32));
        data = data | ((dst_cancellation_offset as u256) << (STAGE_DST_CANCELLATION * 32));
        
        Timelocks { data }
    }
    
    /// Extract values from compact format to explicit format
    /// Unpacks the u256 data back into individual timelock values
    fun extract_from_compact_timelocks(timelocks: &Timelocks): ExplicitTimelocks {
        let data = timelocks.data;
        
        // Extract deployed_at from highest 32 bits
        let deployed_at = ((data >> DEPLOYED_AT_OFFSET) & 0xffffffff) as u64;
        
        // Extract each offset from its respective 32-bit slot
        let src_withdrawal_offset = ((data >> (STAGE_SRC_WITHDRAWAL * 32)) & 0xffffffff) as u64;
        let src_public_withdrawal_offset = ((data >> (STAGE_SRC_PUBLIC_WITHDRAWAL * 32)) & 0xffffffff) as u64;
        let src_cancellation_offset = ((data >> (STAGE_SRC_CANCELLATION * 32)) & 0xffffffff) as u64;
        let src_public_cancellation_offset = ((data >> (STAGE_SRC_PUBLIC_CANCELLATION * 32)) & 0xffffffff) as u64;
        let dst_withdrawal_offset = ((data >> (STAGE_DST_WITHDRAWAL * 32)) & 0xffffffff) as u64;
        let dst_public_withdrawal_offset = ((data >> (STAGE_DST_PUBLIC_WITHDRAWAL * 32)) & 0xffffffff) as u64;
        let dst_cancellation_offset = ((data >> (STAGE_DST_CANCELLATION * 32)) & 0xffffffff) as u64;
        
        ExplicitTimelocks {
            deployed_at,
            src_withdrawal_offset,
            src_public_withdrawal_offset,
            src_cancellation_offset,
            src_public_cancellation_offset,
            dst_withdrawal_offset,
            dst_public_withdrawal_offset,
            dst_cancellation_offset,
        }
    }
    
    /// Ensure timestamp is within u64 range for safe conversion
    fun safe_timestamp_conversion(timestamp: u256): u64 {
        assert!(timestamp <= 18446744073709551615, EINVALID_TIME); // Max u64 value
        (timestamp as u64)
    }

    /// Create a new Timelocks structure with validation
    /// All timelock offsets must be in ascending order for security
    public fun create_timelocks(
        src_withdrawal_offset: u64,
        src_public_withdrawal_offset: u64,
        src_cancellation_offset: u64,
        src_public_cancellation_offset: u64,
        dst_withdrawal_offset: u64,
        dst_public_withdrawal_offset: u64,
        dst_cancellation_offset: u64
    ): Timelocks {
        // Validate timelock sequence for security
        assert!(src_withdrawal_offset < src_public_withdrawal_offset, EINVALID_TIMELOCK);
        assert!(src_public_withdrawal_offset < src_cancellation_offset, EINVALID_TIMELOCK);
        assert!(src_cancellation_offset < src_public_cancellation_offset, EINVALID_TIMELOCK);
        assert!(dst_withdrawal_offset < dst_public_withdrawal_offset, EINVALID_TIMELOCK);
        assert!(dst_public_withdrawal_offset < dst_cancellation_offset, EINVALID_TIMELOCK);

        // Create compact timelocks with deployed_at = 0 (will be set when order is created)
        convert_to_compact_timelocks(
            0, // deployed_at will be set when order is created
            src_withdrawal_offset,
            src_public_withdrawal_offset,
            src_cancellation_offset,
            src_public_cancellation_offset,
            dst_withdrawal_offset,
            dst_public_withdrawal_offset,
            dst_cancellation_offset
        )
    }

    /// Set the deployment timestamp for timelocks
    /// Called when an order is actually created to start the timelock countdown
    fun set_deployed_at(timelocks: Timelocks, timestamp: u64): Timelocks {
        let data = timelocks.data;
        
        // Clear the deployed_at bits
        let cleared_data = data & (DEPLOYED_AT_MASK ^ ALL_BITS);
        
        // Set new timestamp
        let new_timestamp = (timestamp as u256) << DEPLOYED_AT_OFFSET;
        
        Timelocks {
            data: cleared_data | new_timestamp
        }
    }

    /// Get absolute timestamp for a specific timelock stage
    /// Returns the actual timestamp when the stage becomes active
    fun get_timelock(timelocks: &Timelocks, stage: u8): u64 {
        let data = timelocks.data;
        
        // Get deployed_at from highest 32 bits
        let deployed_at = ((data >> DEPLOYED_AT_OFFSET) & 0xffffffff) as u64;
        
        // Get offset for the specified stage
        let bit_shift = (stage as u8) * 32;
        let stage_offset = ((data >> bit_shift) & 0xffffffff) as u64;
        
        // Return absolute timestamp
        deployed_at + stage_offset
    }

    /// Initialize/Constructor(one-time setup)
    /// Must be called before any swap operations can be performed
    public entry fun initialize_ledger<SrcCoinType>(owner: &signer) {
        let seed = b"fusion_plus_addr";                
        let swap_addr = get_ledger_address();

        if (!exists<SwapLedger>(swap_addr)) {
            // create the account and publish the ledger under *that* account
            let (swap_signer, signer_cap) =
                account::create_resource_account(owner, seed);

            move_to(&swap_signer, SwapLedger {
                orders: table::new(),
                order_id_counter: 0,
                signer_cap,
            });

            coin::register<SrcCoinType>(&swap_signer);
        };
    }

    /*
    ============================================================================
    CROSS-CHAIN ATOMIC SWAP PHASES
    ============================================================================
    
    This contract implements Hash Time Lock Contracts (HTLC) for cross-chain atomic swaps.
    Orders on each chain are independent but linked by the same secret hash.
    
    EXAMPLE FLOW: Base → Aptos Swap
    
    Phase 1: Setup on Source Chain (Base)
    - Maker creates order on Base EVM contract with secret_hash
    - Funds are locked in Base escrow with timelock constraints
    - Order gets order_id
    
    Phase 2: Setup on Destination Chain (Aptos) 
    - Resolver(Taker) obsersve makes's order and calls fund_dst_escrow on Aptos with same secret_hash
    - Funds are locked in Aptos escrow with matching timelock constraints  
    - Order gets order_id 
    
    Phase 3: Claiming Phase
    - Relayer calls claim funds at both chains for maker and taker.
    
    Phase 4: Alternative - Cancellation
    - If timelock expires, original depositors can reclaim their funds
    - Public functions allow anyone to facilitate cancellation/claiming
    */

    /// Maker creates order
    /// This locks maker's funds with the secret_hash, and proposed timelock
    public entry fun create_order<SrcCoinType>(
        maker: &signer,
        src_amount: u64,
        min_dst_amount: u64,
        secret_hash: vector<u8>,
        // Timelock parameters (must match those used on Base chain)
        src_withdrawal_offset: u64,
        src_public_withdrawal_offset: u64,
        src_cancellation_offset: u64,
        src_public_cancellation_offset: u64,
        dst_withdrawal_offset: u64,
        dst_public_withdrawal_offset: u64,
        dst_cancellation_offset: u64
    ) acquires SwapLedger {
        // Validate inputs
        assert!(src_amount > 0, EINVALID_AMOUNT);
        assert!(min_dst_amount > 0, EINVALID_AMOUNT);
        assert!(vector::length(&secret_hash) == 32, EINVALID_SECRET_HASH);
        
        let maker_addr = signer::address_of(maker);
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        
        let ledger = borrow_global_mut<SwapLedger>(module_addr);
        
        // Generate order ID (unique to this chain)
        let order_id = ledger.order_id_counter;
        ledger.order_id_counter = order_id + 1;
        
        // Create escrow addresses
        let src_seed = vector::empty<u8>();
        vector::append(&mut src_seed, b"src_escrow_");
        vector::append(&mut src_seed, bcs::to_bytes(&order_id));
        
        // Create and register the source escrow account
        let (src_escrow_addr, escrow_cap) = ensure_escrow_and_register<SrcCoinType>(&ledger.signer_cap, src_seed);
        
        // Get type info
        let src_coin_type = type_info::type_of<SrcCoinType>();
        
        // Create timelocks with current deployment time
        let timelocks = create_timelocks(
            src_withdrawal_offset,
            src_public_withdrawal_offset,
            src_cancellation_offset,
            src_public_cancellation_offset,
            dst_withdrawal_offset,
            dst_public_withdrawal_offset,
            dst_cancellation_offset
        );
        let timelocks = set_deployed_at(timelocks, timestamp::now_seconds());
        
        // Withdraw funds from maker and deposit to escrow
        let maker_coins = coin::withdraw<SrcCoinType>(maker, src_amount);
        coin::deposit(src_escrow_addr, maker_coins);
        
        // Create order with funded status
        let order = OrderMetadata {
            id: order_id,
            maker_address: maker_addr,
            escrow_address: src_escrow_addr,
            escrow_cap: escrow_cap,
            coin_type: src_coin_type,
            amount: src_amount,
            min_amount: min_dst_amount,
            timelocks,
            secret_hash,
            resolver_address: @0x0,  // Not set for source orders
            revealed_secret: vector::empty<u8>(),
        };
        
        table::add(&mut ledger.orders, order_id, order);

        // Emit event
        event::emit(OrderCreated {
            order_id,
            maker: maker_addr,
            escrow_address: src_escrow_addr,
            amount: src_amount,
            min_amount: min_dst_amount,
            secret_hash,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Resolver(Taker) creates destination escrow
    /// This locks resolver's fund under the same secret hash provided by Maker.
    public entry fun fund_dst_escrow<CoinType>(
        resolver: &signer,
        dst_amount: u64,
        secret_hash: vector<u8>,
        // Timelock parameters (will be matched on Base chain)
        src_withdrawal_offset: u64,
        src_public_withdrawal_offset: u64,
        src_cancellation_offset: u64,
        src_public_cancellation_offset: u64,
        dst_withdrawal_offset: u64,
        dst_public_withdrawal_offset: u64,
        dst_cancellation_offset: u64
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        let order_id = ledger.order_id_counter;
        ledger.order_id_counter = order_id + 1;

        // Create / register destination escrow
        let dst_seed = vector::empty<u8>();
        vector::append(&mut dst_seed, b"dst_escrow_");
        vector::append(&mut dst_seed, bcs::to_bytes(&order_id));

        // Create and register the destination escrow account
        let (dst_escrow_addr, escrow_cap) = ensure_escrow_and_register<CoinType>(&ledger.signer_cap, dst_seed);
        
        // Move the resolver's funds
        let dst_coins = coin::withdraw<CoinType>(resolver, dst_amount);
        coin::deposit(dst_escrow_addr, dst_coins);

        // Create timelocks with current deployment time
        let timelocks = create_timelocks(
            src_withdrawal_offset,
            src_public_withdrawal_offset,
            src_cancellation_offset,
            src_public_cancellation_offset,
            dst_withdrawal_offset,
            dst_public_withdrawal_offset,
            dst_cancellation_offset
        );
        let timelocks = set_deployed_at(timelocks, timestamp::now_seconds());

        let resolver_addr = signer::address_of(resolver);

        // Create order with funded status
        let order = OrderMetadata {
            id: order_id,
            maker_address: @0x0,  // Not set for destination orders
            escrow_address: dst_escrow_addr,
            escrow_cap: escrow_cap,
            coin_type: type_info::type_of<CoinType>(),
            amount: dst_amount,
            min_amount: 0,
            timelocks,
            secret_hash,
            resolver_address: resolver_addr,
            revealed_secret: vector::empty<u8>(),
        };

        table::add(&mut ledger.orders, order_id, order);

        // Emit event
        event::emit(OrderCreated {
            order_id,
            maker: resolver_addr,
            escrow_address: dst_escrow_addr,
            amount: dst_amount,
            min_amount: 0,
            secret_hash,
            timestamp: timestamp::now_seconds(),
        });
    }
    
    /// PHASE 3: Claiming - Resolver Claims Destination Funds
    /// Relayer calls when secret is provided by maker for resolver.
    /// This completes the atomic swap
    public entry fun claim_funds<SrcCoinType>(
        resolver: &signer,
        order_id: u64,
        secret: vector<u8>
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that order hasn't expired (using timelocks)
        let current_time = timestamp::now_seconds();
        let cancellation_time = get_timelock(&order.timelocks, 2); // SRC_CANCELLATION
        assert!(current_time < cancellation_time, EORDER_EXPIRED);

        // Check that withdrawal period has started
        let withdrawal_time = get_timelock(&order.timelocks, 0); // SRC_WITHDRAWAL
        assert!(current_time >= withdrawal_time, EINVALID_TIME);

        // Check that secret hasn't been revealed yet (order not already completed)
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify secret hash using Keccak256
        let computed_hash = aptos_hash::keccak256(secret);
        assert!(computed_hash == order.secret_hash, EINVALID_SECRET);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Store the revealed secret
        order.revealed_secret = secret;

        let resolver_addr = signer::address_of(resolver);

        // Transfer funds from escrow to resolver
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        // Make sure escrow has sufficient funds
        assert!(escrow_balance >= order.amount, EINSUFFICIENT_AMOUNT);

        // Withdraw from escrow and deposit to resolver
        let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
        coin::deposit(resolver_addr, coins);

        // Emit event
        event::emit(OrderFilled {
            order_id,
            resolver: resolver_addr,
            secret,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PHASE 3: Claiming - Maker Claims Source Funds
    /// Relayer calls when secret is provided by maker after confirming resolver escrow on destination.
    /// This completes the atomic swap
    public entry fun claim_dst_funds<DstCoinType>(
        maker: &signer,
        order_id: u64,
        secret: vector<u8>
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that order hasn't expired (using timelocks)
        let current_time = timestamp::now_seconds();
        let cancellation_time = get_timelock(&order.timelocks, 6); // DST_CANCELLATION
        assert!(current_time < cancellation_time, EORDER_EXPIRED);

        // Check that withdrawal period has started
        let withdrawal_time = get_timelock(&order.timelocks, 4); // DST_WITHDRAWAL
        assert!(current_time >= withdrawal_time, EINVALID_TIME);

        // Check that secret hasn't been revealed yet (order not already completed)
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify secret hash using Keccak256
        let computed_hash = aptos_hash::keccak256(secret);
        assert!(computed_hash == order.secret_hash, EINVALID_SECRET);

        // Verify coin type matches
        assert!(type_info::type_of<DstCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Store the revealed secret
        order.revealed_secret = secret;

        let maker_addr = signer::address_of(maker);

        // Transfer funds from escrow to maker
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<DstCoinType>(order.escrow_address);
        
        // Make sure escrow has sufficient funds
        assert!(escrow_balance >= order.amount, EINSUFFICIENT_AMOUNT);

        // Withdraw from escrow and deposit to maker
        let coins = coin::withdraw<DstCoinType>(&escrow_signer, order.amount);
        coin::deposit(maker_addr, coins);

        // Emit event
        event::emit(OrderFilled {
            order_id,
            resolver: maker_addr,
            secret,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PHASE 4: Cancellation - Source Order Cancellation
    /// Maker can cancel and reclaim funds if order has expired without completion
    /// Only available after cancellation timelock period
    public entry fun cancel_swap<SrcCoinType>(
        maker: &signer,
        order_id: u64
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that cancellation period has started
        let current_time = timestamp::now_seconds();
        let cancellation_time = get_timelock(&order.timelocks, 2); // SRC_CANCELLATION
        assert!(current_time >= cancellation_time, EINVALID_TIME);

        // Order must not have been completed already
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Verify caller is the maker
        let maker_addr = signer::address_of(maker);
        assert!(maker_addr == order.maker_address, EINVALID_MAKER);

        // Mark as cancelled by setting a dummy revealed secret (non-empty)
        order.revealed_secret = vector::singleton(0u8);

        // Return funds from escrow to maker
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        if (escrow_balance >= order.amount) {
            let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
            coin::deposit(order.maker_address, coins);
        };

        // Emit event
        event::emit(OrderCancelled {
            order_id,
            maker: maker_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PHASE 4: Cancellation - Destination Order Cancellation
    /// Resolver can cancel and reclaim funds if order has expired without completion
    /// Only available after destination cancellation timelock period
    public entry fun cancel_dst_swap<DstCoinType>(
        resolver: &signer,
        order_id: u64
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that cancellation period has started
        let current_time = timestamp::now_seconds();
        let cancellation_time = get_timelock(&order.timelocks, 6); // DST_CANCELLATION
        assert!(current_time >= cancellation_time, EINVALID_TIME);

        // Order must not have been completed already
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify coin type matches
        assert!(type_info::type_of<DstCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Verify caller is the resolver
        let resolver_addr = signer::address_of(resolver);
        assert!(resolver_addr == order.resolver_address, EINVALID_RESOLVER);

        // Mark as cancelled by setting a dummy revealed secret (non-empty)
        order.revealed_secret = vector::singleton(0u8);

        // Return funds from escrow to resolver
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<DstCoinType>(order.escrow_address);
        
        if (escrow_balance >= order.amount) {
            let coins = coin::withdraw<DstCoinType>(&escrow_signer, order.amount);
            coin::deposit(order.resolver_address, coins);
        };

        // Emit event
        event::emit(OrderCancelled {
            order_id,
            maker: resolver_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /*
    ============================================================================
    PUBLIC FUNCTIONS FOR RELAYER/THIRD-PARTY FACILITATION
    ============================================================================
    
    These functions allow relayers or other third parties to facilitate swaps
    during public periods, providing additional safety and automation.
    */

    /// PUBLIC CLAIMING: Source Order Public Withdrawal
    /// Anyone can claim source funds by providing the secret during public withdrawal period
    /// Useful for relayers to facilitate swaps automatically
    public entry fun public_withdraw<SrcCoinType>(
        caller: &signer,
        order_id: u64,
        secret: vector<u8>,
        recipient: address
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that public withdrawal period has started
        let current_time = timestamp::now_seconds();
        let public_withdrawal_time = get_timelock(&order.timelocks, 1); // SRC_PUBLIC_WITHDRAWAL
        assert!(current_time >= public_withdrawal_time, EINVALID_TIME);

        // Check that cancellation period hasn't started
        let cancellation_time = get_timelock(&order.timelocks, 2); // SRC_CANCELLATION
        assert!(current_time < cancellation_time, EORDER_EXPIRED);

        // Check that secret hasn't been revealed yet (order not already completed)
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify secret hash using Keccak256
        let computed_hash = aptos_hash::keccak256(secret);
        assert!(computed_hash == order.secret_hash, EINVALID_SECRET);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Store the revealed secret
        order.revealed_secret = secret;

        let caller_addr = signer::address_of(caller);

        // Transfer funds from escrow to recipient
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        // Make sure escrow has sufficient funds
        assert!(escrow_balance >= order.amount, EINSUFFICIENT_AMOUNT);

        // Withdraw from escrow and deposit to recipient
        let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
        coin::deposit(recipient, coins);

        // Emit event
        event::emit(OrderFilled {
            order_id,
            resolver: caller_addr,
            secret,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PUBLIC CLAIMING: Destination Order Public Withdrawal
    /// Anyone can claim destination funds by providing the secret during public withdrawal period
    /// Useful for relayers to facilitate swaps automatically
    public entry fun public_withdraw_dst<DstCoinType>(
        caller: &signer,
        order_id: u64,
        secret: vector<u8>,
        recipient: address
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that public withdrawal period has started
        let current_time = timestamp::now_seconds();
        let public_withdrawal_time = get_timelock(&order.timelocks, 5); // DST_PUBLIC_WITHDRAWAL
        assert!(current_time >= public_withdrawal_time, EINVALID_TIME);

        // Check that cancellation period hasn't started
        let cancellation_time = get_timelock(&order.timelocks, 6); // DST_CANCELLATION
        assert!(current_time < cancellation_time, EORDER_EXPIRED);

        // Check that secret hasn't been revealed yet (order not already completed)
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify secret hash using Keccak256
        let computed_hash = aptos_hash::keccak256(secret);
        assert!(computed_hash == order.secret_hash, EINVALID_SECRET);

        // Verify coin type matches
        assert!(type_info::type_of<DstCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Store the revealed secret
        order.revealed_secret = secret;

        let caller_addr = signer::address_of(caller);

        // Transfer funds from escrow to recipient
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<DstCoinType>(order.escrow_address);
        
        // Make sure escrow has sufficient funds
        assert!(escrow_balance >= order.amount, EINSUFFICIENT_AMOUNT);

        // Withdraw from escrow and deposit to recipient
        let coins = coin::withdraw<DstCoinType>(&escrow_signer, order.amount);
        coin::deposit(recipient, coins);

        // Emit event
        event::emit(OrderFilled {
            order_id,
            resolver: caller_addr,
            secret,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PUBLIC CANCELLATION: Source Order Public Cancellation
    /// Anyone can cancel source order and return funds to maker during public cancellation period
    /// Provides safety mechanism when original maker cannot cancel themselves
    public entry fun public_cancel<SrcCoinType>(
        caller: &signer,
        order_id: u64
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that public cancellation period has started
        let current_time = timestamp::now_seconds();
        let public_cancellation_time = get_timelock(&order.timelocks, 3); // SRC_PUBLIC_CANCELLATION
        assert!(current_time >= public_cancellation_time, EINVALID_TIME);

        // Order must not have been completed already
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify coin type matches
        assert!(type_info::type_of<SrcCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Mark as cancelled by setting a dummy revealed secret (non-empty)
        order.revealed_secret = vector::singleton(0u8);

        // Return funds from escrow to maker
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<SrcCoinType>(order.escrow_address);
        
        if (escrow_balance >= order.amount) {
            let coins = coin::withdraw<SrcCoinType>(&escrow_signer, order.amount);
            coin::deposit(order.maker_address, coins);
        };

        // Emit event
        event::emit(OrderCancelled {
            order_id,
            maker: order.maker_address,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// PUBLIC CANCELLATION: Destination Order Public Cancellation  
    /// Anyone can cancel destination order and return funds to resolver during public cancellation period
    /// Provides safety mechanism when original resolver cannot cancel themselves
    public entry fun public_cancel_dst<DstCoinType>(
        caller: &signer,
        order_id: u64
    ) acquires SwapLedger {
        let module_addr = get_ledger_address();
        assert!(exists<SwapLedger>(module_addr), ESWAP_LEDGER_DOES_NOT_EXIST);
        let ledger = borrow_global_mut<SwapLedger>(module_addr);

        assert!(table::contains(&ledger.orders, order_id), EORDER_DOES_NOT_EXIST);
        let order = table::borrow_mut(&mut ledger.orders, order_id);

        // Check that destination cancellation period has started
        let current_time = timestamp::now_seconds();
        let dst_cancellation_time = get_timelock(&order.timelocks, 6); // DST_CANCELLATION
        assert!(current_time >= dst_cancellation_time, EINVALID_TIME);

        // Order must not have been completed already
        assert!(vector::is_empty(&order.revealed_secret), EORDER_ALREADY_FILLED_OR_CANCELLED);

        // Verify coin type matches
        assert!(type_info::type_of<DstCoinType>() == order.coin_type, EINVALID_COIN_TYPE);

        // Mark as cancelled by setting a dummy revealed secret (non-empty)
        order.revealed_secret = vector::singleton(0u8);

        // Return funds from escrow to resolver
        let escrow_signer = account::create_signer_with_capability(&order.escrow_cap);
        let escrow_balance = coin::balance<DstCoinType>(order.escrow_address);
        
        if (escrow_balance >= order.amount) {
            let coins = coin::withdraw<DstCoinType>(&escrow_signer, order.amount);
            coin::deposit(order.resolver_address, coins);
        };

        // Emit event
        event::emit(OrderCancelled {
            order_id,
            maker: order.resolver_address,
            timestamp: timestamp::now_seconds(),
        });
    }

    /*
    ============================================================================
    HELPER FUNCTIONS
    ============================================================================
    */

    /// Helper function to create and register an escrow account
    /// Creates a resource account under the swap ledger for holding escrowed funds
    fun ensure_escrow_and_register<CoinType>(
        parent_cap: &SignerCapability,
        seed: vector<u8>
    ): (address, SignerCapability) {
        // Create signer for the parent (swap) account
        let parent_signer = account::create_signer_with_capability(parent_cap);

        // Create the escrow resource account
        let (escrow_signer, escrow_cap) =
            account::create_resource_account(&parent_signer, seed);

        let escrow_addr = signer::address_of(&escrow_signer);

        // Register CoinType inside the escrow account
        if (!coin::is_account_registered<CoinType>(escrow_addr)) {
            coin::register<CoinType>(&escrow_signer);
        };

        (escrow_addr, escrow_cap)
    }
}