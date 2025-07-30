/// Dutch auction module for dynamic pricing in limit orders
/// Handles rate bump calculations, gas price adjustments, and piecewise linear auction curves
module crosschain_escrow_factory::dutch_auction {
    use std::error;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_std::math64;

    /// Error codes
    const E_INVALID_AUCTION_CONFIG: u64 = 1;
    const E_INVALID_TIME_DELTA: u64 = 2;
    const E_INVALID_RATE_BUMP: u64 = 3;
    const E_AUCTION_NOT_STARTED: u64 = 4;
    const E_INVALID_POINT_COUNT: u64 = 5;

    /// Constants
    const BASE_POINTS: u256 = 10_000_000; // 100% in basis points (10^7)
    const GAS_PRICE_BASE: u64 = 1_000_000; // 1000 means 1 Gwei equivalent

    /// Represents a point in the auction curve
    struct AuctionPoint has copy, drop, store {
        rate_bump: u32,      // Rate bump in basis points
        time_delta: u16,     // Time delta from previous point in seconds
    }

    /// Auction configuration
    struct AuctionConfig has copy, drop, store {
        gas_bump_estimate: u32,     // Gas bump estimate (3 bytes equivalent)
        gas_price_estimate: u32,    // Gas price estimate (4 bytes equivalent)
        start_time: u32,            // Auction start time (4 bytes equivalent)
        duration: u32,              // Auction duration in seconds (3 bytes equivalent)
        initial_rate_bump: u32,     // Initial rate bump (3 bytes equivalent)
        auction_points: vector<AuctionPoint>, // Piecewise linear points
    }

    /// Creates a new auction point
    public fun new_auction_point(rate_bump: u32, time_delta: u16): AuctionPoint {
        AuctionPoint {
            rate_bump,
            time_delta,
        }
    }

    /// Creates a new auction configuration
    public fun new_auction_config(
        gas_bump_estimate: u32,
        gas_price_estimate: u32,
        start_time: u32,
        duration: u32,
        initial_rate_bump: u32,
        auction_points: vector<AuctionPoint>,
    ): AuctionConfig {
        // Validate that points are in ascending time order
        validate_auction_points(&auction_points);
        
        AuctionConfig {
            gas_bump_estimate,
            gas_price_estimate,
            start_time,
            duration,
            initial_rate_bump,
            auction_points,
        }
    }

    /// Validates that auction points are properly ordered
    fun validate_auction_points(points: &vector<AuctionPoint>) {
        let length = vector::length(points);
        if (length == 0) return;
        
        // Ensure no point has zero time delta (except potentially the first)
        validate_auction_points_impl(points, 0, length);
    }
    
    /// Helper function for validating auction points
    fun validate_auction_points_impl(points: &vector<AuctionPoint>, index: u64, length: u64) {
        if (index >= length) return;
        
        let point = vector::borrow(points, index);
        // Time deltas should be reasonable (not too large)
        assert!(point.time_delta > 0 || index == 0, error::invalid_argument(E_INVALID_TIME_DELTA));
        
        validate_auction_points_impl(points, index + 1, length);
    }

    /// Calculates the current rate bump based on auction configuration
    public fun calculate_rate_bump(config: &AuctionConfig, current_gas_price: u64): u64 {
        let gas_bump = calculate_gas_bump(config, current_gas_price);
        let auction_bump = calculate_auction_bump(config);
        
        // Return auction_bump - gas_bump, but ensure it doesn't underflow
        if (auction_bump > gas_bump) {
            auction_bump - gas_bump
        } else {
            0
        }
    }

    /// Calculates gas-related bump
    fun calculate_gas_bump(config: &AuctionConfig, current_gas_price: u64): u64 {
        if (config.gas_bump_estimate == 0 || config.gas_price_estimate == 0) {
            return 0
        };

        // gas_bump = gas_bump_estimate * current_gas_price / gas_price_estimate / GAS_PRICE_BASE
        let gas_bump = ((config.gas_bump_estimate as u64) * current_gas_price) 
                       / (config.gas_price_estimate as u64) 
                       / GAS_PRICE_BASE;
        gas_bump
    }

    /// Calculates auction-specific bump based on time and curve
    fun calculate_auction_bump(config: &AuctionConfig): u64 {
        let current_time = timestamp::now_seconds();
        let auction_start = (config.start_time as u64);
        let auction_finish = auction_start + (config.duration as u64);

        if (current_time <= auction_start) {
            // Before auction starts
            return (config.initial_rate_bump as u64)
        } else if (current_time >= auction_finish) {
            // After auction ends
            return 0
        };

        // During auction - calculate based on piecewise linear function
        calculate_piecewise_rate_bump(config, current_time, auction_start, auction_finish)
    }

    /// Calculates rate bump using piecewise linear interpolation
    fun calculate_piecewise_rate_bump(
        config: &AuctionConfig,
        current_time: u64,
        auction_start: u64,
        auction_finish: u64
    ): u64 {
        let time_from_start = current_time - auction_start;
        let initial_rate_bump = (config.initial_rate_bump as u64);
        let points_length = vector::length(&config.auction_points);
        
        calculate_piecewise_rate_bump_impl(
            config, 
            time_from_start, 
            0, // current_point_time
            initial_rate_bump, // current_rate_bump
            0, // index
            points_length,
            auction_finish - auction_start
        )
    }
    
    /// Helper function for piecewise rate bump calculation
    fun calculate_piecewise_rate_bump_impl(
        config: &AuctionConfig,
        time_from_start: u64,
        current_point_time: u64,
        current_rate_bump: u64,
        index: u64,
        points_length: u64,
        auction_duration: u64
    ): u64 {
        if (index >= points_length) {
            // After all points - interpolate to zero at auction finish
            return interpolate_rate_bump(
                time_from_start,
                current_point_time,
                auction_duration,
                current_rate_bump,
                0
            )
        };
        
        let point = vector::borrow(&config.auction_points, index);
        let next_point_time = current_point_time + (point.time_delta as u64);
        let next_rate_bump = (point.rate_bump as u64);

        if (time_from_start <= next_point_time) {
            // We're in this segment - interpolate
            interpolate_rate_bump(
                time_from_start,
                current_point_time,
                next_point_time,
                current_rate_bump,
                next_rate_bump
            )
        } else {
            // Continue to next point
            calculate_piecewise_rate_bump_impl(
                config,
                time_from_start,
                next_point_time,
                next_rate_bump,
                index + 1,
                points_length,
                auction_duration
            )
        }
    }

    /// Linear interpolation between two rate bumps
    fun interpolate_rate_bump(
        current_time: u64,
        start_time: u64,
        end_time: u64,
        start_rate: u64,
        end_rate: u64
    ): u64 {
        if (end_time == start_time) {
            return start_rate
        };

        let time_progress = current_time - start_time;
        let time_duration = end_time - start_time;

        // Linear interpolation: start_rate + (end_rate - start_rate) * progress / duration
        if (end_rate >= start_rate) {
            let rate_increase = end_rate - start_rate;
            start_rate + (rate_increase * time_progress) / time_duration
        } else {
            let rate_decrease = start_rate - end_rate;
            start_rate - (rate_decrease * time_progress) / time_duration
        }
    }

    /// Calculates making amount based on taking amount and rate bump
    public fun calculate_making_amount(
        order_making_amount: u64,
        order_taking_amount: u64,
        taking_amount: u64,
        rate_bump: u64
    ): u64 {
        // making_amount = order_making_amount * taking_amount * BASE_POINTS / 
        //                 (order_taking_amount * (BASE_POINTS + rate_bump))
        
        let numerator = (order_making_amount as u256) * (taking_amount as u256) * BASE_POINTS;
        let denominator = (order_taking_amount as u256) * (BASE_POINTS + (rate_bump as u256));
        
        ((numerator / denominator) as u64)
    }

    /// Calculates taking amount based on making amount and rate bump
    public fun calculate_taking_amount(
        order_making_amount: u64,
        order_taking_amount: u64,
        making_amount: u64,
        rate_bump: u64
    ): u64 {
        // taking_amount = order_taking_amount * making_amount * (BASE_POINTS + rate_bump) / 
        //                 (order_making_amount * BASE_POINTS)
        // Use ceiling division for taking amount
        
        let numerator = (order_taking_amount as u256) * (making_amount as u256) * (BASE_POINTS + (rate_bump as u256));
        let denominator = (order_making_amount as u256) * BASE_POINTS;
        
        // Ceiling division: (numerator + denominator - 1) / denominator
        (((numerator + denominator - 1) / denominator) as u64)
    }

    /// Checks if auction has started
    public fun has_auction_started(config: &AuctionConfig): bool {
        timestamp::now_seconds() >= (config.start_time as u64)
    }

    /// Checks if auction has finished
    public fun has_auction_finished(config: &AuctionConfig): bool {
        let finish_time = (config.start_time as u64) + (config.duration as u64);
        timestamp::now_seconds() >= finish_time
    }

    /// Gets the current auction phase (0: not started, 1: active, 2: finished)
    public fun get_auction_phase(config: &AuctionConfig): u8 {
        if (!has_auction_started(config)) {
            0
        } else if (!has_auction_finished(config)) {
            1
        } else {
            2
        }
    }

    /// Gets auction finish time
    public fun get_auction_finish_time(config: &AuctionConfig): u64 {
        (config.start_time as u64) + (config.duration as u64)
    }

    /// Gets auction progress as percentage (0-100)
    public fun get_auction_progress(config: &AuctionConfig): u64 {
        if (!has_auction_started(config)) {
            return 0
        };
        if (has_auction_finished(config)) {
            return 100
        };

        let current_time = timestamp::now_seconds();
        let start_time = (config.start_time as u64);
        let duration = (config.duration as u64);
        
        let elapsed = current_time - start_time;
        (elapsed * 100) / duration
    }

    // Getter functions for AuctionConfig
    public fun get_gas_bump_estimate(config: &AuctionConfig): u32 { config.gas_bump_estimate }
    public fun get_gas_price_estimate(config: &AuctionConfig): u32 { config.gas_price_estimate }
    public fun get_start_time(config: &AuctionConfig): u32 { config.start_time }
    public fun get_duration(config: &AuctionConfig): u32 { config.duration }
    public fun get_initial_rate_bump(config: &AuctionConfig): u32 { config.initial_rate_bump }
    public fun get_auction_points(config: &AuctionConfig): vector<AuctionPoint> { config.auction_points }

    // Getter functions for AuctionPoint
    public fun get_point_rate_bump(point: &AuctionPoint): u32 { point.rate_bump }
    public fun get_point_time_delta(point: &AuctionPoint): u16 { point.time_delta }

    // Constants accessors
    public fun base_points(): u256 { BASE_POINTS }
    public fun gas_price_base(): u64 { GAS_PRICE_BASE }
}