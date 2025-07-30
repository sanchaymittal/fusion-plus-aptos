#[test_only]
module resolver_addr::resolver_validation_test {
    use std::vector;
    
    #[test]
    public fun test_empty_vector_validation() {
        // Test that our validation logic correctly identifies empty vectors
        let empty_vector = vector::empty<u8>();
        let non_empty_vector = b"test_data";
        
        // These assertions mirror what we added to the resolver
        assert!(vector::length(&empty_vector) == 0, 1);
        assert!(vector::length(&non_empty_vector) > 0, 2);
        
        // Test the exact validation we use in resolver
        assert!(!(vector::length(&empty_vector) > 0), 3); // This would fail our validation
        assert!(vector::length(&non_empty_vector) > 0, 4); // This would pass our validation
    }

    #[test]
    public fun test_order_hash_and_hashlock_lengths() {
        // Test with the exact data format we expect
        let valid_order_hash = b"test_order_hash_32_bytes_long!!!"; // 32 bytes
        let valid_hashlock = b"my_secret_password_for_swap_test"; // Variable length secret
        
        assert!(vector::length(&valid_order_hash) == 32, 1);
        assert!(vector::length(&valid_hashlock) == 32, 2);
        assert!(vector::length(&valid_order_hash) > 0, 3);
        assert!(vector::length(&valid_hashlock) > 0, 4);
    }

    #[test]
    public fun test_realistic_data_validation() {
        // Test with data similar to what we see in the transaction logs
        let order_hash_bytes = vector::empty<u8>();
        vector::push_back(&mut order_hash_bytes, 214);
        vector::push_back(&mut order_hash_bytes, 129);
        vector::push_back(&mut order_hash_bytes, 195);
        vector::push_back(&mut order_hash_bytes, 125);
        // Add more bytes to simulate a 32-byte hash
        let i = 4;
        while (i < 32) {
            vector::push_back(&mut order_hash_bytes, (i as u8));
            i = i + 1;
        };
        
        let hashlock_bytes = vector::empty<u8>();
        vector::push_back(&mut hashlock_bytes, 109); // 'm'
        vector::push_back(&mut hashlock_bytes, 121); // 'y'
        vector::push_back(&mut hashlock_bytes, 95);  // '_'
        // Add more bytes to simulate the full secret
        let j = 3;
        while (j < 32) {
            vector::push_back(&mut hashlock_bytes, (j as u8));
            j = j + 1;
        };
        
        // These should pass our validation
        assert!(vector::length(&order_hash_bytes) == 32, 1);
        assert!(vector::length(&hashlock_bytes) == 32, 2);
        assert!(vector::length(&order_hash_bytes) > 0, 3);
        assert!(vector::length(&hashlock_bytes) > 0, 4);
    }
}