#[test_only]
module crosschain_escrow_factory::create2_test {
    use std::vector;
    use std::bcs;
    use aptos_framework::account;
    
    use crosschain_escrow_factory::create2;

    // Test addresses for consistent testing
    const TEST_FACTORY_ADDRESS: address = @0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    const ANOTHER_FACTORY_ADDRESS: address = @0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321;

    #[test]
    public fun test_new_seed_creation() {
        let salt = b"test_salt_123";
        let src_seed = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_src());
        let dst_seed = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_dst());

        // Verify seed components
        assert!(create2::get_factory_address(&src_seed) == TEST_FACTORY_ADDRESS, 1);
        assert!(create2::get_salt(&src_seed) == salt, 2);
        assert!(create2::get_implementation_type(&src_seed) == create2::implementation_src(), 3);

        assert!(create2::get_factory_address(&dst_seed) == TEST_FACTORY_ADDRESS, 4);
        assert!(create2::get_salt(&dst_seed) == salt, 5);
        assert!(create2::get_implementation_type(&dst_seed) == create2::implementation_dst(), 6);
    }

    #[test]
    public fun test_implementation_type_constants() {
        assert!(create2::implementation_src() == 0, 1);
        assert!(create2::implementation_dst() == 1, 2);
        assert!(create2::implementation_src() != create2::implementation_dst(), 3);
    }

    #[test]
    public fun test_compute_address_deterministic() {
        let salt = b"deterministic_test";
        let src_seed = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_src());
        
        // Same seed should always produce same address
        let address1 = create2::compute_address(&src_seed);
        let address2 = create2::compute_address(&src_seed);
        assert!(address1 == address2, 1);

        // Different seeds should produce different addresses
        let dst_seed = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_dst());
        let dst_address = create2::compute_address(&dst_seed);
        assert!(address1 != dst_address, 2);
    }

    #[test]
    public fun test_compute_src_vs_dst_addresses() {
        let salt = b"src_vs_dst_test";
        
        let src_address = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        let dst_address = create2::compute_dst_address(TEST_FACTORY_ADDRESS, salt);
        
        // Source and destination addresses should be different
        assert!(src_address != dst_address, 1);
        
        // Same parameters should always produce same addresses
        let src_address2 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        let dst_address2 = create2::compute_dst_address(TEST_FACTORY_ADDRESS, salt);
        
        assert!(src_address == src_address2, 2);
        assert!(dst_address == dst_address2, 3);
    }

    #[test]
    public fun test_different_factories_produce_different_addresses() {
        let salt = b"factory_test";
        
        let address1 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        let address2 = create2::compute_src_address(ANOTHER_FACTORY_ADDRESS, salt);
        
        // Different factory addresses should produce different escrow addresses
        assert!(address1 != address2, 1);
    }

    #[test]
    public fun test_different_salts_produce_different_addresses() {
        let salt1 = b"salt_one";
        let salt2 = b"salt_two";
        
        let address1 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt1);
        let address2 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt2);
        
        // Different salts should produce different addresses
        assert!(address1 != address2, 1);
    }

    #[test]
    public fun test_validate_address() {
        let salt = b"validation_test";
        let computed_address = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        
        // Validation should pass for correct parameters
        assert!(create2::validate_address(
            computed_address,
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_src()
        ), 1);

        // Validation should fail for wrong implementation type
        assert!(!create2::validate_address(
            computed_address,
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_dst()
        ), 2);

        // Validation should fail for wrong factory address
        assert!(!create2::validate_address(
            computed_address,
            ANOTHER_FACTORY_ADDRESS,
            salt,
            create2::implementation_src()
        ), 3);

        // Validation should fail for wrong salt
        let wrong_salt = b"wrong_salt";
        assert!(!create2::validate_address(
            computed_address,
            TEST_FACTORY_ADDRESS,
            wrong_salt,
            create2::implementation_src()
        ), 4);
    }

    #[test]
    public fun test_generate_salt_from_immutables_hash() {
        let immutables_hash = b"test_immutables_hash_32_bytes!!";
        let salt = create2::generate_salt_from_immutables_hash(immutables_hash);
        
        // Salt should be identical to the immutables hash
        assert!(salt == immutables_hash, 1);
        assert!(vector::length(&salt) == vector::length(&immutables_hash), 2);
    }

    #[test]
    public fun test_verify_address_generation() {
        let immutables_hash = b"verify_test_hash_32_bytes_long!";
        
        // Generate address using immutables hash
        let salt = create2::generate_salt_from_immutables_hash(immutables_hash);
        let computed_address = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        
        // Verification should pass
        assert!(create2::verify_address_generation(
            computed_address,
            TEST_FACTORY_ADDRESS,
            immutables_hash,
            create2::implementation_src()
        ), 1);

        // Verification should fail for wrong implementation type
        assert!(!create2::verify_address_generation(
            computed_address,
            TEST_FACTORY_ADDRESS,
            immutables_hash,
            create2::implementation_dst()
        ), 2);

        // Verification should fail for wrong immutables hash
        let wrong_hash = b"wrong_immutables_hash_32_bytes!";
        assert!(!create2::verify_address_generation(
            computed_address,
            TEST_FACTORY_ADDRESS,
            wrong_hash,
            create2::implementation_src()
        ), 3);
    }

    #[test]
    public fun test_create_resource_address_deterministic() {
        let salt = b"resource_test";
        
        // Resource addresses should be deterministic
        let resource_addr1 = create2::create_resource_address(
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_src()
        );
        let resource_addr2 = create2::create_resource_address(
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_src()
        );
        
        assert!(resource_addr1 == resource_addr2, 1);

        // Different implementation types should produce different resource addresses
        let dst_resource_addr = create2::create_resource_address(
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_dst()
        );
        
        assert!(resource_addr1 != dst_resource_addr, 2);
    }

    #[test]
    public fun test_compute_vs_create_resource_address() {
        let salt = b"compute_vs_create";
        
        let computed_addr = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt);
        let resource_addr = create2::create_resource_address(
            TEST_FACTORY_ADDRESS,
            salt,
            create2::implementation_src()
        );
        
        // These should be different as they use different generation methods
        // compute_address uses SHA3 hash, create_resource_address uses Aptos account system
        assert!(computed_addr != resource_addr, 1);
    }

    #[test]
    public fun test_empty_salt_handling() {
        let empty_salt = vector::empty<u8>();
        
        // Should work with empty salt
        let address1 = create2::compute_src_address(TEST_FACTORY_ADDRESS, empty_salt);
        let address2 = create2::compute_src_address(TEST_FACTORY_ADDRESS, empty_salt);
        
        assert!(address1 == address2, 1);
        
        // Empty salt should produce different address than non-empty salt
        let non_empty_salt = b"non_empty";
        let address3 = create2::compute_src_address(TEST_FACTORY_ADDRESS, non_empty_salt);
        
        assert!(address1 != address3, 2);
    }

    #[test]
    public fun test_large_salt_handling() {
        // Create a large salt (100 bytes)
        let large_salt = vector::empty<u8>();
        let i = 0;
        while (i < 100) {
            vector::push_back(&mut large_salt, ((i % 256) as u8));
            i = i + 1;
        };
        
        let address1 = create2::compute_src_address(TEST_FACTORY_ADDRESS, large_salt);
        let address2 = create2::compute_src_address(TEST_FACTORY_ADDRESS, large_salt);
        
        // Should handle large salts deterministically
        assert!(address1 == address2, 1);
        assert!(vector::length(&large_salt) == 100, 2);
    }

    #[test]
    public fun test_seed_components_independence() {
        let salt = b"independence_test";
        
        // Create seeds with different components
        let seed1 = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_src());
        let seed2 = create2::new_seed(ANOTHER_FACTORY_ADDRESS, salt, create2::implementation_src());
        let seed3 = create2::new_seed(TEST_FACTORY_ADDRESS, salt, create2::implementation_dst());
        
        let addr1 = create2::compute_address(&seed1);
        let addr2 = create2::compute_address(&seed2);
        let addr3 = create2::compute_address(&seed3);
        
        // All addresses should be different
        assert!(addr1 != addr2, 1);
        assert!(addr1 != addr3, 2);
        assert!(addr2 != addr3, 3);
    }

    #[test]
    public fun test_consistent_hashing_with_bcs_encoding() {
        let salt = b"bcs_test";
        
        // Test that BCS encoding is consistent
        let factory_bytes1 = bcs::to_bytes(&TEST_FACTORY_ADDRESS);
        let factory_bytes2 = bcs::to_bytes(&TEST_FACTORY_ADDRESS);
        
        assert!(factory_bytes1 == factory_bytes2, 1);
        
        // Test that different addresses produce different encodings
        let other_factory_bytes = bcs::to_bytes(&ANOTHER_FACTORY_ADDRESS);
        assert!(factory_bytes1 != other_factory_bytes, 2);
    }

    #[test]
    public fun test_address_collision_resistance() {
        // Test that small changes in input produce significantly different outputs
        let salt1 = b"collision_test_1";
        let salt2 = b"collision_test_2"; // Only last character different
        
        let addr1 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt1);
        let addr2 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt2);
        
        // Small input differences should result in completely different addresses
        assert!(addr1 != addr2, 1);
        
        // Test with implementation type difference
        let addr3 = create2::compute_src_address(TEST_FACTORY_ADDRESS, salt1);
        let addr4 = create2::compute_dst_address(TEST_FACTORY_ADDRESS, salt1);
        
        assert!(addr3 != addr4, 2);
    }
}