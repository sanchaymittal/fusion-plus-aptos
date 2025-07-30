/// Timelock module for managing time-based access control in cross-chain atomic swaps
/// Handles multiple stages of escrow lifecycle with different time constraints
module crosschain_escrow_factory::timelock {
    use std::error;
    use aptos_framework::timestamp;

    /// Error codes
    const E_INVALID_TIME: u64 = 1;
    const E_INVALID_STAGE: u64 = 2;
    const E_TIME_NOT_REACHED: u64 = 3;
    const E_TIME_PASSED: u64 = 4;

    /// Timelock stages for source chain
    const STAGE_SRC_WITHDRAWAL: u8 = 0;
    const STAGE_SRC_PUBLIC_WITHDRAWAL: u8 = 1;
    const STAGE_SRC_CANCELLATION: u8 = 2;
    const STAGE_SRC_PUBLIC_CANCELLATION: u8 = 3;

    /// Timelock stages for destination chain
    const STAGE_DST_WITHDRAWAL: u8 = 4;
    const STAGE_DST_PUBLIC_WITHDRAWAL: u8 = 5;
    const STAGE_DST_CANCELLATION: u8 = 6;

    /// Represents timelock configuration for an escrow
    /// Stores deployment timestamp and relative delays for each stage
    struct Timelocks has copy, drop, store {
        deployed_at: u64,
        src_withdrawal_delay: u32,
        src_public_withdrawal_delay: u32,
        src_cancellation_delay: u32,
        src_public_cancellation_delay: u32,
        dst_withdrawal_delay: u32,
        dst_public_withdrawal_delay: u32,
        dst_cancellation_delay: u32,
    }

    /// Creates a new Timelocks configuration
    public fun new(
        src_withdrawal_delay: u32,
        src_public_withdrawal_delay: u32,
        src_cancellation_delay: u32,
        src_public_cancellation_delay: u32,
        dst_withdrawal_delay: u32,
        dst_public_withdrawal_delay: u32,
        dst_cancellation_delay: u32,
    ): Timelocks {
        // Validate that delays are in logical order
        assert!(src_withdrawal_delay <= src_public_withdrawal_delay, error::invalid_argument(E_INVALID_TIME));
        assert!(src_public_withdrawal_delay <= src_cancellation_delay, error::invalid_argument(E_INVALID_TIME));
        assert!(src_cancellation_delay <= src_public_cancellation_delay, error::invalid_argument(E_INVALID_TIME));
        assert!(dst_withdrawal_delay <= dst_public_withdrawal_delay, error::invalid_argument(E_INVALID_TIME));
        assert!(dst_public_withdrawal_delay <= dst_cancellation_delay, error::invalid_argument(E_INVALID_TIME));

        Timelocks {
            deployed_at: 0, // Will be set when escrow is deployed
            src_withdrawal_delay,
            src_public_withdrawal_delay,
            src_cancellation_delay,
            src_public_cancellation_delay,
            dst_withdrawal_delay,
            dst_public_withdrawal_delay,
            dst_cancellation_delay,
        }
    }

    /// Sets the deployment timestamp (called when escrow is created)
    public fun set_deployed_at(timelocks: &mut Timelocks, deployed_at: u64) {
        timelocks.deployed_at = deployed_at;
    }

    /// Creates a new Timelocks with deployment timestamp set
    public fun with_deployed_at(timelocks: Timelocks, deployed_at: u64): Timelocks {
        Timelocks {
            src_withdrawal_delay: timelocks.src_withdrawal_delay,
            src_public_withdrawal_delay: timelocks.src_public_withdrawal_delay,
            src_cancellation_delay: timelocks.src_cancellation_delay,
            src_public_cancellation_delay: timelocks.src_public_cancellation_delay,
            dst_withdrawal_delay: timelocks.dst_withdrawal_delay,
            dst_public_withdrawal_delay: timelocks.dst_public_withdrawal_delay,
            dst_cancellation_delay: timelocks.dst_cancellation_delay,
            deployed_at,
        }
    }

    /// Gets the absolute timestamp for a specific stage
    public fun get_stage_time(timelocks: &Timelocks, stage: u8): u64 {
        let delay = if (stage == STAGE_SRC_WITHDRAWAL) {
            (timelocks.src_withdrawal_delay as u64)
        } else if (stage == STAGE_SRC_PUBLIC_WITHDRAWAL) {
            (timelocks.src_public_withdrawal_delay as u64)
        } else if (stage == STAGE_SRC_CANCELLATION) {
            (timelocks.src_cancellation_delay as u64)
        } else if (stage == STAGE_SRC_PUBLIC_CANCELLATION) {
            (timelocks.src_public_cancellation_delay as u64)
        } else if (stage == STAGE_DST_WITHDRAWAL) {
            (timelocks.dst_withdrawal_delay as u64)
        } else if (stage == STAGE_DST_PUBLIC_WITHDRAWAL) {
            (timelocks.dst_public_withdrawal_delay as u64)
        } else if (stage == STAGE_DST_CANCELLATION) {
            (timelocks.dst_cancellation_delay as u64)
        } else {
            abort error::invalid_argument(E_INVALID_STAGE)
        };
        
        timelocks.deployed_at + delay
    }

    /// Checks if current time is after the specified stage time
    public fun is_after_stage(timelocks: &Timelocks, stage: u8): bool {
        let stage_time = get_stage_time(timelocks, stage);
        timestamp::now_seconds() >= stage_time
    }

    /// Checks if current time is before the specified stage time
    public fun is_before_stage(timelocks: &Timelocks, stage: u8): bool {
        let stage_time = get_stage_time(timelocks, stage);
        timestamp::now_seconds() < stage_time
    }

    /// Asserts that current time is after the specified stage
    public fun assert_after_stage(timelocks: &Timelocks, stage: u8) {
        assert!(is_after_stage(timelocks, stage), error::invalid_state(E_TIME_NOT_REACHED));
    }

    /// Asserts that current time is before the specified stage
    public fun assert_before_stage(timelocks: &Timelocks, stage: u8) {
        assert!(is_before_stage(timelocks, stage), error::invalid_state(E_TIME_PASSED));
    }

    /// Checks if we're in a specific time window (after start, before end)
    public fun is_in_window(timelocks: &Timelocks, start_stage: u8, end_stage: u8): bool {
        is_after_stage(timelocks, start_stage) && is_before_stage(timelocks, end_stage)
    }

    /// Asserts that we're in a specific time window
    public fun assert_in_window(timelocks: &Timelocks, start_stage: u8, end_stage: u8) {
        assert!(is_in_window(timelocks, start_stage, end_stage), error::invalid_state(E_INVALID_TIME));
    }

    /// Gets the rescue start time (for emergency fund recovery)
    public fun get_rescue_start_time(timelocks: &Timelocks, rescue_delay: u64): u64 {
        timelocks.deployed_at + rescue_delay
    }

    /// Checks if rescue period has started
    public fun is_rescue_time(timelocks: &Timelocks, rescue_delay: u64): bool {
        timestamp::now_seconds() >= get_rescue_start_time(timelocks, rescue_delay)
    }

    // Getter functions
    public fun get_deployed_at(timelocks: &Timelocks): u64 { timelocks.deployed_at }
    public fun get_src_withdrawal_delay(timelocks: &Timelocks): u32 { timelocks.src_withdrawal_delay }
    public fun get_src_public_withdrawal_delay(timelocks: &Timelocks): u32 { timelocks.src_public_withdrawal_delay }
    public fun get_src_cancellation_delay(timelocks: &Timelocks): u32 { timelocks.src_cancellation_delay }
    public fun get_src_public_cancellation_delay(timelocks: &Timelocks): u32 { timelocks.src_public_cancellation_delay }
    public fun get_dst_withdrawal_delay(timelocks: &Timelocks): u32 { timelocks.dst_withdrawal_delay }
    public fun get_dst_public_withdrawal_delay(timelocks: &Timelocks): u32 { timelocks.dst_public_withdrawal_delay }
    public fun get_dst_cancellation_delay(timelocks: &Timelocks): u32 { timelocks.dst_cancellation_delay }

    // Constants for stage access
    public fun stage_src_withdrawal(): u8 { STAGE_SRC_WITHDRAWAL }
    public fun stage_src_public_withdrawal(): u8 { STAGE_SRC_PUBLIC_WITHDRAWAL }
    public fun stage_src_cancellation(): u8 { STAGE_SRC_CANCELLATION }
    public fun stage_src_public_cancellation(): u8 { STAGE_SRC_PUBLIC_CANCELLATION }
    public fun stage_dst_withdrawal(): u8 { STAGE_DST_WITHDRAWAL }
    public fun stage_dst_public_withdrawal(): u8 { STAGE_DST_PUBLIC_WITHDRAWAL }
    public fun stage_dst_cancellation(): u8 { STAGE_DST_CANCELLATION }
}