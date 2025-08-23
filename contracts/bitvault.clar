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