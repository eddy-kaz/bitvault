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