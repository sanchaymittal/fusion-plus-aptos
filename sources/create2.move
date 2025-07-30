/// Deterministic address generation module
/// Provides CREATE2-equivalent functionality for predictable escrow addresses
module crosschain_escrow_factory::create2 {
    use std::hash;
    use std::bcs;
    use aptos_framework::account;
    use aptos_std::from_bcs;

    /// Error codes
    const E_INVALID_SEED: u64 = 1;
    const E_ADDRESS_GENERATION_FAILED: u64 = 2;

    /// Represents the components needed for deterministic address generation
    struct AddressSeed has copy, drop {
        factory_address: address,
        salt: vector<u8>,
        implementation_type: u8, // 0 for src, 1 for dst
    }

    /// Implementation types
    const IMPLEMENTATION_SRC: u8 = 0;
    const IMPLEMENTATION_DST: u8 = 1;

    /// Creates a new address seed
    public fun new_seed(
        factory_address: address,
        salt: vector<u8>,
        implementation_type: u8
    ): AddressSeed {
        AddressSeed {
            factory_address,
            salt,
            implementation_type,
        }
    }

    /// Computes a deterministic address based on the seed
    /// This simulates Ethereum's CREATE2 functionality
    public fun compute_address(seed: &AddressSeed): address {
        // Create a unique identifier by combining all components
        let combined_data = bcs::to_bytes(&seed.factory_address);
        std::vector::append(&mut combined_data, seed.salt);
        std::vector::append(&mut combined_data, bcs::to_bytes(&seed.implementation_type));
        
        // Hash the combined data to get deterministic bytes
        let hash_bytes = hash::sha3_256(combined_data);
        
        // Convert first 32 bytes to address (Aptos addresses are 32 bytes)
        from_bcs::to_address(hash_bytes)
    }

    /// Computes address for source escrow
    public fun compute_src_address(factory_address: address, salt: vector<u8>): address {
        let seed = new_seed(factory_address, salt, IMPLEMENTATION_SRC);
        compute_address(&seed)
    }

    /// Computes address for destination escrow
    public fun compute_dst_address(factory_address: address, salt: vector<u8>): address {
        let seed = new_seed(factory_address, salt, IMPLEMENTATION_DST);
        compute_address(&seed)
    }

    /// Validates that a computed address matches the expected pattern
    public fun validate_address(
        computed_address: address,
        factory_address: address,
        salt: vector<u8>,
        implementation_type: u8
    ): bool {
        let seed = new_seed(factory_address, salt, implementation_type);
        let expected_address = compute_address(&seed);
        computed_address == expected_address
    }

    /// Creates a resource address for escrow deployment
    /// This is used when actually deploying the escrow contract
    public fun create_resource_address(
        factory_address: address,
        salt: vector<u8>,
        implementation_type: u8
    ): address {
        // Combine factory address and salt for resource address generation
        let seed_bytes = bcs::to_bytes(&factory_address);
        std::vector::append(&mut seed_bytes, salt);
        std::vector::append(&mut seed_bytes, bcs::to_bytes(&implementation_type));
        
        account::create_resource_address(&factory_address, seed_bytes)
    }

    /// Generates salt from escrow immutables hash
    /// This ensures the same immutables always generate the same address
    public fun generate_salt_from_immutables_hash(immutables_hash: vector<u8>): vector<u8> {
        // Use the immutables hash directly as salt
        immutables_hash
    }

    /// Verifies that an address was generated with specific parameters
    public fun verify_address_generation(
        address_to_verify: address,
        factory_address: address,
        immutables_hash: vector<u8>,
        implementation_type: u8
    ): bool {
        let salt = generate_salt_from_immutables_hash(immutables_hash);
        validate_address(address_to_verify, factory_address, salt, implementation_type)
    }

    // Getter functions for the seed components
    public fun get_factory_address(seed: &AddressSeed): address {
        seed.factory_address
    }

    public fun get_salt(seed: &AddressSeed): vector<u8> {
        seed.salt
    }

    public fun get_implementation_type(seed: &AddressSeed): u8 {
        seed.implementation_type
    }

    // Constants for implementation types
    public fun implementation_src(): u8 { IMPLEMENTATION_SRC }
    public fun implementation_dst(): u8 { IMPLEMENTATION_DST }
}