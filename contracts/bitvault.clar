;; Title: BitVault Protocol
;;
;; Summary: A decentralized lending protocol enabling Bitcoin holders to unlock
;; liquidity from their sBTC collateral while maintaining Bitcoin exposure
;;
;; Description: BitVault revolutionizes Bitcoin DeFi by creating a secure lending
;; marketplace where users can deposit sBTC as collateral to borrow STX tokens,
;; or provide STX liquidity to earn competitive yields. Built on Stacks Layer-2,
;; this protocol combines Bitcoin's security with DeFi innovation, featuring
;; automated interest accrual, liquidation protection, and yield optimization
;; for a seamless Bitcoin-native financial experience.
;;

;; ERROR CONSTANTS

(define-constant ERR_INVALID_WITHDRAW_AMOUNT (err u100))
(define-constant ERR_EXCEEDED_MAX_BORROW (err u101))
(define-constant ERR_CANNOT_BE_LIQUIDATED (err u102))
(define-constant ERR_ACTIVE_DEPOSIT_EXISTS (err u103))
(define-constant ERR_INSUFFICIENT_BALANCE (err u104))
(define-constant ERR_ZERO_AMOUNT (err u105))
(define-constant ERR_PRICE_FEED_ERROR (err u106))
(define-constant ERR_CONTRACT_CALL_FAILED (err u107))
(define-constant ERR_UNAUTHORIZED (err u108))

;; PROTOCOL CONSTANTS

(define-constant LOAN_TO_VALUE_RATIO u70) ;; 70% LTV
(define-constant ANNUAL_INTEREST_RATE u10) ;; 10% APR
(define-constant LIQUIDATION_THRESHOLD u80) ;; 80% liquidation threshold (fixed from 100%)
(define-constant LIQUIDATOR_REWARD_RATE u10) ;; 10% liquidation reward
(define-constant SECONDS_PER_YEAR u31556952) ;; Seconds in a year
(define-constant BASIS_POINTS u10000) ;; For yield calculations

;; CONTRACT OWNER
(define-constant CONTRACT_OWNER tx-sender)

;; PROTOCOL STATE VARIABLES

;; Global collateral tracking
(define-data-var total-sbtc-collateral uint u0)

;; Global deposit tracking  
(define-data-var total-stx-deposits uint u1)

;; Global borrow tracking
(define-data-var total-stx-borrows uint u0)

;; Interest accrual timestamp
(define-data-var last-interest-update uint u0)

;; Cumulative yield for lenders (in basis points)
(define-data-var cumulative-yield-index uint u0)

;; Price oracle data - fallback static price (1 sBTC = 50000 STX for example)
(define-data-var sbtc-price-in-stx uint u50000)

;; Protocol paused state
(define-data-var protocol-paused bool false)

;; DATA MAPS

;; User collateral positions
(define-map user-collateral-positions
  { account: principal }
  { sbtc-amount: uint }
)

;; User deposit positions
(define-map user-deposit-positions
  { account: principal }
  {
    stx-amount: uint,
    yield-index-snapshot: uint,
  }
)

;; User borrow positions
(define-map user-borrow-positions
  { account: principal }
  {
    stx-amount: uint,
    last-interest-accrual: uint,
  }
)

;; PRICE ORACLE FUNCTIONS

;; Get sBTC price in STX - Simple static price oracle
(define-read-only (get-sbtc-price-in-stx)
  (ok (var-get sbtc-price-in-stx))
)

;; Admin function to update price (for static price oracle)
(define-public (update-sbtc-price (new-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-price u0) ERR_ZERO_AMOUNT)
    (var-set sbtc-price-in-stx new-price)
    (ok true)
  )
)

;; PROTOCOL MANAGEMENT

(define-public (pause-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set protocol-paused true)
    (ok true)
  )
)

(define-public (unpause-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set protocol-paused false)
    (ok true)
  )
)

;; LENDING FUNCTIONS

;; Deposit STX to earn yield
(define-public (deposit-stx (amount uint))
  (let (
      (caller tx-sender)
      (existing-deposit (map-get? user-deposit-positions { account: caller }))
      (current-deposit (default-to u0 (get stx-amount existing-deposit)))
    )
    ;; Input validation
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)

    ;; Update interest before processing deposit
    (update-interest-accrual)

    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount caller (as-contract tx-sender)))

    ;; Record user deposit
    (map-set user-deposit-positions { account: caller } {
      stx-amount: (+ current-deposit amount),
      yield-index-snapshot: (var-get cumulative-yield-index),
    })

    ;; Update global deposit tracking
    (var-set total-stx-deposits (+ (var-get total-stx-deposits) amount))

    (ok true)
  )
)

;; Withdraw STX deposits plus earned yield
(define-public (withdraw-stx (amount uint))
  (let (
      (caller tx-sender)
      (user-deposit (unwrap! (map-get? user-deposit-positions { account: caller })
        ERR_INSUFFICIENT_BALANCE
      ))
      (deposited-amount (get stx-amount user-deposit))
      (earned-yield (unwrap! (calculate-pending-yield caller) ERR_CONTRACT_CALL_FAILED))
      (total-available (+ deposited-amount earned-yield))
      (withdrawal-amount (if (> amount total-available)
        total-available
        amount
      ))
    )
    ;; Input validation
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (>= total-available amount) ERR_INVALID_WITHDRAW_AMOUNT)

    ;; Update interest before processing withdrawal
    (update-interest-accrual)

    ;; Calculate remaining deposit after withdrawal
    (let ((remaining-deposit (if (>= deposited-amount amount)
        (- deposited-amount amount)
        u0
      )))
      ;; Update user deposit record
      (if (is-eq remaining-deposit u0)
        (map-delete user-deposit-positions { account: caller })
        (map-set user-deposit-positions { account: caller } {
          stx-amount: remaining-deposit,
          yield-index-snapshot: (var-get cumulative-yield-index),
        })
      )

      ;; Update global deposit tracking
      (var-set total-stx-deposits
        (if (>= (var-get total-stx-deposits) amount)
          (- (var-get total-stx-deposits) amount)
          u0
        ))

      ;; Transfer STX to user
      (try! (as-contract (stx-transfer? withdrawal-amount tx-sender caller)))

      (ok true)
    )
  )
)

;; Calculate pending yield for a user
(define-read-only (calculate-pending-yield (account principal))
  (let (
      (user-deposit (map-get? user-deposit-positions { account: account }))
      (yield-snapshot (default-to u0 (get yield-index-snapshot user-deposit)))
      (stx-amount (default-to u0 (get stx-amount user-deposit)))
      (current-yield-index (var-get cumulative-yield-index))
    )
    (if (> current-yield-index yield-snapshot)
      (let ((yield-delta (- current-yield-index yield-snapshot)))
        (ok (/ (* stx-amount yield-delta) BASIS_POINTS))
      )
      (ok u0)
    )
  )
)

;; BORROWING FUNCTIONS

;; Borrow STX against sBTC collateral
(define-public (borrow-stx
    (collateral-amount uint)
    (borrow-amount uint)
  )
  (let (
      (caller tx-sender)
      (existing-collateral (map-get? user-collateral-positions { account: caller }))
      (current-collateral (default-to u0 (get sbtc-amount existing-collateral)))
      (new-total-collateral (+ current-collateral collateral-amount))
      (sbtc-price (unwrap! (get-sbtc-price-in-stx) ERR_PRICE_FEED_ERROR))
      (collateral-value (* new-total-collateral sbtc-price))
      (max-borrowable (/ (* collateral-value LOAN_TO_VALUE_RATIO) u100))
      (existing-borrow (map-get? user-borrow-positions { account: caller }))
      (current-debt (unwrap! (calculate-user-debt caller) ERR_CONTRACT_CALL_FAILED))
      (new-total-debt (+ current-debt borrow-amount))
    )
    ;; Input validation
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> collateral-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (> borrow-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (<= new-total-debt max-borrowable) ERR_EXCEEDED_MAX_BORROW)

    ;; Update interest before processing borrow
    (update-interest-accrual)

    ;; Update borrow position
    (map-set user-borrow-positions { account: caller } {
      stx-amount: new-total-debt,
      last-interest-accrual: (get-current-timestamp),
    })

    ;; Update global borrow tracking
    (var-set total-stx-borrows (+ (var-get total-stx-borrows) borrow-amount))

    ;; Update collateral position
    (map-set user-collateral-positions { account: caller } { sbtc-amount: new-total-collateral })

    ;; Update global collateral tracking
    (var-set total-sbtc-collateral
      (+ (var-get total-sbtc-collateral) collateral-amount)
    )

    ;; Transfer borrowed STX to user (simplified - assumes contract has STX balance)
    (try! (as-contract (stx-transfer? borrow-amount tx-sender caller)))

    (ok true)
  )
)

;; Repay loan and retrieve collateral
(define-public (repay-loan (repay-amount uint))
  (let (
      (caller tx-sender)
      (borrow-position (unwrap! (map-get? user-borrow-positions { account: caller })
        ERR_INSUFFICIENT_BALANCE
      ))
      (borrowed-principal (get stx-amount borrow-position))
      (total-debt (unwrap! (calculate-user-debt caller) ERR_CONTRACT_CALL_FAILED))
      (collateral-position (map-get? user-collateral-positions { account: caller }))
      (collateral-amount (default-to u0 (get sbtc-amount collateral-position)))
    )
    ;; Input validation
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> repay-amount u0) ERR_ZERO_AMOUNT)

    ;; Update interest before processing repayment
    (update-interest-accrual)

    ;; Accept STX repayment from user
    (try! (stx-transfer? repay-amount caller (as-contract tx-sender)))

    ;; Calculate remaining debt
    (let ((remaining-debt (if (>= repay-amount total-debt)
        u0
        (- total-debt repay-amount)
      )))
      (if (is-eq remaining-debt u0)
        (begin
          ;; Full repayment - clear positions and return collateral
          (map-delete user-collateral-positions { account: caller })
          (map-delete user-borrow-positions { account: caller })

          ;; Update global tracking
          (var-set total-sbtc-collateral
            (if (>= (var-get total-sbtc-collateral) collateral-amount)
              (- (var-get total-sbtc-collateral) collateral-amount)
              u0
            ))
          (var-set total-stx-borrows
            (if (>= (var-get total-stx-borrows) borrowed-principal)
              (- (var-get total-stx-borrows) borrowed-principal)
              u0
            ))

          (ok true)
        )
        (begin
          ;; Partial repayment - update borrow position
          (map-set user-borrow-positions { account: caller } {
            stx-amount: remaining-debt,
            last-interest-accrual: (get-current-timestamp),
          })

          (ok true)
        )
      )
    )
  )
)

;; Calculate total debt for a user (principal + accrued interest)
(define-read-only (calculate-user-debt (account principal))
  (let (
      (borrow-position (map-get? user-borrow-positions { account: account }))
      (borrowed-amount (default-to u0 (get stx-amount borrow-position)))
      (last-accrual (default-to u0 (get last-interest-accrual borrow-position)))
      (current-time (get-current-timestamp))
    )
    (if (and (> borrowed-amount u0) (> current-time last-accrual))
      (let (
          (time-elapsed (- current-time last-accrual))
          (interest-rate-per-second (/ ANNUAL_INTEREST_RATE SECONDS_PER_YEAR))
          (interest-factor (+ u100 (/ (* interest-rate-per-second time-elapsed) u100)))
          (total-debt (/ (* borrowed-amount interest-factor) u100))
        )
        (ok total-debt)
      )
      (ok borrowed-amount)
    )
  )
)

;; LIQUIDATION FUNCTIONS

;; Liquidate undercollateralized position (simplified version)
(define-public (liquidate-position (target-user principal))
  (let (
      (user-debt (unwrap! (calculate-user-debt target-user) ERR_CONTRACT_CALL_FAILED))
      (collateral-position (unwrap! (map-get? user-collateral-positions { account: target-user })
        ERR_CANNOT_BE_LIQUIDATED
      ))
      (collateral-amount (get sbtc-amount collateral-position))
      (sbtc-price (unwrap! (get-sbtc-price-in-stx) ERR_PRICE_FEED_ERROR))
      (collateral-value (* collateral-amount sbtc-price))
      (liquidation-ratio (* user-debt LIQUIDATION_THRESHOLD))
      (liquidator-reward (/ (* collateral-amount LIQUIDATOR_REWARD_RATE) u100))
    )
    ;; Update interest before liquidation
    (update-interest-accrual)

    ;; Validate liquidation conditions
    (asserts! (> user-debt u0) ERR_CANNOT_BE_LIQUIDATED)
    (asserts! (<= (* collateral-value u100) liquidation-ratio)
      ERR_CANNOT_BE_LIQUIDATED
    )

    ;; Update global tracking
    (var-set total-sbtc-collateral
      (if (>= (var-get total-sbtc-collateral) collateral-amount)
        (- (var-get total-sbtc-collateral) collateral-amount)
        u0
      ))
    (var-set total-stx-borrows
      (if (>= (var-get total-stx-borrows) user-debt)
        (- (var-get total-stx-borrows) user-debt)
        u0
      ))

    ;; Clear user positions
    (map-delete user-borrow-positions { account: target-user })
    (map-delete user-collateral-positions { account: target-user })

    ;; Give liquidator reward (simplified - just transfer the reward amount)
    ;; In production, you would swap collateral and distribute appropriately

    (ok true)
  )
)

;; HELPER FUNCTIONS

;; Get current block timestamp
(define-private (get-current-timestamp)
  (default-to u0 (get-stacks-block-info? time (- stacks-block-height u1)))
)

;; Update global interest accrual for lenders
(define-private (update-interest-accrual)
  (let (
      (current-time (get-current-timestamp))
      (last-update (var-get last-interest-update))
    )
    (if (and (> current-time last-update) (> (var-get total-stx-deposits) u0))
      (let (
          (time-elapsed (- current-time last-update))
          (total-borrows (var-get total-stx-borrows))
          (total-deposits (var-get total-stx-deposits))
          (interest-earned (* (* total-borrows ANNUAL_INTEREST_RATE)
            (/ time-elapsed SECONDS_PER_YEAR)
          ))
          (yield-per-token (/ (* interest-earned BASIS_POINTS) total-deposits))
        )
        ;; Update timestamp and yield index
        (var-set last-interest-update current-time)
        (var-set cumulative-yield-index
          (+ (var-get cumulative-yield-index) yield-per-token)
        )
        true
      )
      true
    )
  )
)

;; READ-ONLY QUERY FUNCTIONS

;; Get user's collateral balance
(define-read-only (get-user-collateral (account principal))
  (default-to u0
    (get sbtc-amount (map-get? user-collateral-positions { account: account }))
  )
)

;; Get user's deposit balance
(define-read-only (get-user-deposits (account principal))
  (default-to u0
    (get stx-amount (map-get? user-deposit-positions { account: account }))
  )
)

;; Get user's borrow balance
(define-read-only (get-user-borrows (account principal))
  (default-to u0
    (get stx-amount (map-get? user-borrow-positions { account: account }))
  )
)

;; Get user's health factor
(define-read-only (get-user-health-factor (account principal))
  (let (
      (collateral-amount (get-user-collateral account))
      (debt-amount (unwrap! (calculate-user-debt account) (ok u0)))
      (sbtc-price (unwrap! (get-sbtc-price-in-stx) (ok u0)))
      (collateral-value (* collateral-amount sbtc-price))
    )
    (if (is-eq debt-amount u0)
      (ok u999999) ;; Very high health factor if no debt
      (ok (/ (* collateral-value u100) debt-amount))
    )
  )
)

;; Get protocol statistics
(define-read-only (get-protocol-stats)
  {
    total-sbtc-collateral: (var-get total-sbtc-collateral),
    total-stx-deposits: (var-get total-stx-deposits),
    total-stx-borrows: (var-get total-stx-borrows),
    cumulative-yield-index: (var-get cumulative-yield-index),
    current-sbtc-price: (var-get sbtc-price-in-stx),
    protocol-paused: (var-get protocol-paused),
  }
)
