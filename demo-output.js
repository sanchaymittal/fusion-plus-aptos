// Demo script to show the beautiful test output formatting for hackathon presentation

// Beautiful console output utilities
const colors = {
    reset: '\x1b[0m',
    bright: '\x1b[1m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    magenta: '\x1b[35m',
    cyan: '\x1b[36m',
    white: '\x1b[37m'
}

// Mock transaction log for demo
const transactionLog = [
    { chain: 'Ethereum', type: 'Order Fill', hash: '0x1234567890abcdef...', description: 'Filled order for 100.00 USDC', timestamp: Date.now() },
    { chain: 'Aptos', type: 'Escrow Creation', hash: '0xfedcba0987654321...', description: 'Created destination escrow for token transfer', timestamp: Date.now() + 1000 },
    { chain: 'Aptos', type: 'Token Withdrawal', hash: '0xabcdef1234567890...', description: 'User withdrew tokens from escrow', timestamp: Date.now() + 2000 },
    { chain: 'Ethereum', type: 'Resolver Withdrawal', hash: '0x9876543210fedcba...', description: 'Resolver withdrew USDC from escrow', timestamp: Date.now() + 3000 },
    { chain: 'Ethereum', type: 'Escrow Creation', hash: '0x5555666677778888...', description: 'Created destination escrow for USDC transfer', timestamp: Date.now() + 4000 },
    { chain: 'Aptos', type: 'Token Withdrawal', hash: '0x9999aaaabbbbcccc...', description: 'Resolver withdrew Aptos tokens from escrow', timestamp: Date.now() + 5000 }
]

const log = {
    header: (title) => {
        const border = '═'.repeat(60)
        console.log(`\n${colors.cyan}${colors.bright}╔${border}╗${colors.reset}`)
        console.log(`${colors.cyan}${colors.bright}║${title.padStart(30 + title.length / 2).padEnd(60)}║${colors.reset}`)
        console.log(`${colors.cyan}${colors.bright}╚${border}╝${colors.reset}\n`)
    },
    section: (title) => {
        console.log(`\n${colors.yellow}${colors.bright}🔸 ${title}${colors.reset}`)
        console.log(`${colors.yellow}${'─'.repeat(50)}${colors.reset}`)
    },
    success: (message) => {
        console.log(`${colors.green}${colors.bright}✅ ${message}${colors.reset}`)
    },
    info: (message) => {
        console.log(`${colors.blue}ℹ️  ${message}${colors.reset}`)
    },
    warning: (message) => {
        console.log(`${colors.yellow}⚠️  ${message}${colors.reset}`)
    },
    transaction: (chain, type, hash, description) => {
        console.log(`${colors.magenta}🔗 [${chain}] ${type}: ${hash}${colors.reset}`)
        console.log(`   ${colors.white}${description}${colors.reset}`)
    },
    balance: (label, before, after, decimals = 6) => {
        const beforeFormatted = (Number(before) / Math.pow(10, decimals)).toFixed(2)
        const afterFormatted = (Number(after) / Math.pow(10, decimals)).toFixed(2)
        const change = Number(after) - Number(before)
        const changeFormatted = (change / Math.pow(10, decimals)).toFixed(2)
        const changeColor = change >= 0 ? colors.green : colors.red
        const changeSymbol = change >= 0 ? '+' : ''
        console.log(`   ${colors.white}${label}: ${beforeFormatted} → ${afterFormatted} ${changeColor}(${changeSymbol}${changeFormatted})${colors.reset}`)
    },
    summary: () => {
        log.header('🎉 TRANSACTION SUMMARY 🎉')
        if (transactionLog.length === 0) {
            console.log(`${colors.yellow}No transactions recorded${colors.reset}`)
            return
        }
        
        console.log(`${colors.bright}Total Transactions: ${transactionLog.length}${colors.reset}\n`)
        
        const chainGroups = transactionLog.reduce((acc, tx) => {
            if (!acc[tx.chain]) acc[tx.chain] = []
            acc[tx.chain].push(tx)
            return acc
        }, {})
        
        Object.entries(chainGroups).forEach(([chain, txs]) => {
            console.log(`${colors.cyan}${colors.bright}📍 ${chain.toUpperCase()} (${txs.length} transactions)${colors.reset}`)
            txs.forEach((tx, index) => {
                const timeStr = new Date(tx.timestamp).toLocaleTimeString()
                console.log(`   ${index + 1}. ${colors.magenta}${tx.type}${colors.reset}: ${tx.hash}`)
                console.log(`      ${colors.white}${tx.description} (${timeStr})${colors.reset}`)
            })
            console.log()
        })
        
        const border = '═'.repeat(60)
        console.log(`${colors.green}${colors.bright}╔${border}╗${colors.reset}`)
        console.log(`${colors.green}${colors.bright}║${'🚀 FUSION+ CROSS-CHAIN SWAP DEMO COMPLETE! 🚀'.padStart(30 + 25).padEnd(60)}║${colors.reset}`)
        console.log(`${colors.green}${colors.bright}╚${border}╝${colors.reset}\n`)
    }
}

// Demo the beautified output
log.header('🚀 FUSION+ CROSS-CHAIN SWAP TESTS 🚀')

log.section('Step 1: Generate Cryptographic Secret')
log.info('Secret: 0x1234567890abcdef...')
log.info('SHA3-256 Hash: 12345678...')

log.section('Step 2: Create and Fill Cross-Chain Order')
log.info('Creating order with hash: 0xabcdef123456...')
log.transaction('Ethereum', 'Order Fill', '0x1234567890abcdef1234567890abcdef12345678', 'Filled order for 100.00 USDC')

log.section('Step 3: Create Destination Escrow on Aptos')
log.info('Depositing 99.00 USDC equivalent on Aptos')
log.success('Aptos escrow created at: 0x987654321fedcba987654321fedcba9876543210')

log.section('Step 4: Execute Withdrawals')
log.info('Finality lock period passed - proceeding with withdrawals')
log.info('User withdrawing tokens from Aptos escrow')
log.transaction('Aptos', 'Token Withdrawal', '0xabcdef1234567890abcdef1234567890abcdef12', 'User withdrew tokens from escrow')

log.info('Resolver withdrawing USDC from Ethereum escrow')
log.transaction('Ethereum', 'Resolver Withdrawal', '0x9876543210fedcba9876543210fedcba98765432', 'Resolver withdrew USDC from escrow')

log.section('Step 5: Verify Results')
log.success('Ethereum USDC balances verified!')
log.balance('User USDC', BigInt('1000000000'), BigInt('900000000'), 6)
log.balance('Resolver USDC', BigInt('0'), BigInt('100000000'), 6)

log.success('Aptos token balances verified!')
log.balance('User Aptos Tokens', BigInt('0'), BigInt('9900000000'), 8)

log.success('✨ Ethereum → Aptos swap completed successfully! ✨')

// Second test demo
log.header('🔄 APTOS → ETHEREUM SWAP TEST')

log.section('Step 1: Generate Cryptographic Secret')
log.info('Secret: 0xfedcba0987654321...')
log.info('Aptos Hash: fedcba09...')

log.section('Step 2: Create Cross-Chain Order')
log.info('Order created with salt: 456')
log.info('Making amount: 100.00 Aptos tokens')
log.info('Taking amount: 99.00 USDC')

log.section('Step 3: Sign Order and Create Source Escrow')
log.info('Order signed on Aptos: 0x789abc...')
log.info('Creating source escrow for order: 0x123def...')
log.success('Aptos source escrow created at: 0x456789abcdef456789abcdef456789abcdef4567')

log.section('Step 4: Create Destination Escrow on Ethereum')
log.info('Creating Ethereum destination escrow for order: 0x789abc...')
log.info('Destination escrow will receive 99.00 USDC')
log.transaction('Ethereum', 'Escrow Creation', '0x5555666677778888999900001111222233334444', 'Created destination escrow for USDC transfer')
log.success('Ethereum escrow created at: 0x5555666677778888999900001111222233334444')

log.section('Step 5: Execute Withdrawals')
log.info('Finality lock period passed - proceeding with withdrawals')
log.info('Resolver withdrawing Aptos tokens from escrow')
log.transaction('Aptos', 'Token Withdrawal', '0x9999aaaabbbbcccc9999aaaabbbbcccc9999aaaa', 'Resolver withdrew Aptos tokens from escrow')

log.section('Step 6: Verify Results')
log.success('Aptos token balances verified!')
log.balance('User Aptos Tokens', BigInt('10000000000'), BigInt('10000000000'), 8)
log.success('✨ Aptos → Ethereum swap completed successfully! ✨')

// Display transaction summary
log.summary()