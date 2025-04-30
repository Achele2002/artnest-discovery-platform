;; artnest-marketplace
;; A decentralized NFT marketplace for ArtNest that enables artists to list and sell artwork
;; while automatically enforcing royalty distributions on secondary sales

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LISTING-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PRICE (err u102))
(define-constant ERR-ALREADY-LISTED (err u103))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u104))
(define-constant ERR-TRANSFER-FAILED (err u105))
(define-constant ERR-NOT-OWNER (err u106))
(define-constant ERR-INVALID-ROYALTY (err u107))
(define-constant ERR-UNKNOWN-NFT-CONTRACT (err u108))
(define-constant ERR-LISTING-EXPIRED (err u109))
(define-constant ERR-INVALID-CATEGORY (err u110))

;; Constants
(define-constant PLATFORM-FEE-PERCENT u5)  ;; 5% platform fee
(define-constant MAX-ROYALTY-PERCENT u20)  ;; Max royalty of 20%
(define-constant CONTRACT-OWNER tx-sender)

;; Data structures

;; Supported NFT contracts
(define-map supported-nft-contracts principal bool)

;; Listing information
(define-map listings
  { listing-id: uint }
  {
    seller: principal,
    nft-contract: principal,
    token-id: uint,
    price: uint,
    royalty-percent: uint,
    original-artist: principal,
    created-at: uint,
    expires-at: (optional uint),
    category: (optional (string-ascii 20))
  }
)

;; Track artwork by categories for discovery
(define-map artwork-by-category
  { category: (string-ascii 20) }
  { listing-ids: (list 100 uint) }
)

;; Index to track all active listings
(define-data-var next-listing-id uint u1)

;; Featured collections (curated by platform)
(define-map featured-collections
  { collection-name: (string-ascii 50) }
  { listing-ids: (list 100 uint), featured-until: uint }
)

;; Sales history
(define-map sales-history
  { listing-id: uint, sale-index: uint }
  {
    buyer: principal,
    seller: principal,
    price: uint,
    timestamp: uint,
    royalty-paid: uint
  }
)

;; Track sales count per listing
(define-map listing-sales-count { listing-id: uint } uint)

;; Private functions

;; Calculate royalty amount based on price and percentage
(define-private (calculate-royalty (price uint) (royalty-percent uint))
  (/ (* price royalty-percent) u100)
)

;; Calculate platform fee
(define-private (calculate-platform-fee (price uint))
  (/ (* price PLATFORM-FEE-PERCENT) u100)
)

;; Check if a contract is supported
(define-private (is-supported-contract (contract principal))
  (default-to false (map-get? supported-nft-contracts contract))
)

;; Split payment between seller, artist (royalty), and platform
(define-private (distribute-payment (price uint) (seller principal) (artist principal) (royalty-percent uint))
  (let (
    (royalty-amount (calculate-royalty price royalty-percent))
    (platform-fee (calculate-platform-fee price))
    (seller-amount (- price (+ royalty-amount platform-fee)))
  )
    (begin
      ;; Send royalty to original artist
      (unwrap! (stx-transfer? royalty-amount tx-sender artist) ERR-TRANSFER-FAILED)
      ;; Send platform fee to contract owner
      (unwrap! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER) ERR-TRANSFER-FAILED)
      ;; Send remaining amount to seller
      (unwrap! (stx-transfer? seller-amount tx-sender seller) ERR-TRANSFER-FAILED)
      (ok true)
    )
  )
)

;; Record a sale in the history
(define-private (record-sale (listing-id uint) (listing-data {
                                                  seller: principal,
                                                  nft-contract: principal,
                                                  token-id: uint,
                                                  price: uint,
                                                  royalty-percent: uint,
                                                  original-artist: principal,
                                                  created-at: uint,
                                                  expires-at: (optional uint),
                                                  category: (optional (string-ascii 20))
                                                })
                             (royalty-paid uint))
  (let (
    (sale-index (default-to u0 (map-get? listing-sales-count { listing-id: listing-id })))
    (new-sale-count (+ sale-index u1))
  )
    (begin
      (map-set sales-history
        { listing-id: listing-id, sale-index: sale-index }
        {
          buyer: tx-sender,
          seller: (get seller listing-data),
          price: (get price listing-data),
          timestamp: block-height,
          royalty-paid: royalty-paid
        }
      )
      (map-set listing-sales-count { listing-id: listing-id } new-sale-count)
      (ok true)
    )
  )
)

;; Add listing to category
(define-private (add-to-category (listing-id uint) (category (string-ascii 20)))
  (let (
    (current-listings (default-to { listing-ids: (list) } (map-get? artwork-by-category { category: category })))
    (current-list (get listing-ids current-listings))
  )
    (map-set artwork-by-category
      { category: category }
      { listing-ids: (append current-list listing-id) }
    )
  )
)

;; Remove listing from category
(define-private (remove-from-category (listing-id uint) (category (string-ascii 20)))
  (let (
    (current-listings (default-to { listing-ids: (list) } (map-get? artwork-by-category { category: category })))
    (current-list (get listing-ids current-listings))
    (filtered-list (filter (lambda (id) (not (is-eq id listing-id))) current-list))
  )
    (map-set artwork-by-category
      { category: category }
      { listing-ids: filtered-list }
    )
  )
)

;; Public functions

;; Add a supported NFT contract (admin only)
(define-public (add-supported-contract (contract principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set supported-nft-contracts contract true))
  )
)

;; Remove a supported NFT contract (admin only)
(define-public (remove-supported-contract (contract principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-delete supported-nft-contracts contract))
  )
)

;; Create a new listing
(define-public (create-listing (nft-contract principal) 
                              (token-id uint) 
                              (price uint)
                              (royalty-percent uint)
                              (expires-at (optional uint))
                              (category (optional (string-ascii 20))))
  (let (
    (listing-id (var-get next-listing-id))
  )
    (begin
      ;; Validate inputs
      (asserts! (is-supported-contract nft-contract) ERR-UNKNOWN-NFT-CONTRACT)
      (asserts! (> price u0) ERR-INVALID-PRICE)
      (asserts! (<= royalty-percent MAX-ROYALTY-PERCENT) ERR-INVALID-ROYALTY)
      
      ;; Check token ownership
      (asserts! (is-owner nft-contract token-id tx-sender) ERR-NOT-OWNER)
      
      ;; Ensure escrow of the NFT in the marketplace
      (try! (contract-call? nft-contract transfer token-id tx-sender (as-contract tx-sender)))
      
      ;; Create the listing record
      (map-set listings
        { listing-id: listing-id }
        {
          seller: tx-sender,
          nft-contract: nft-contract,
          token-id: token-id,
          price: price,
          royalty-percent: royalty-percent,
          original-artist: tx-sender,  ;; Original artist is the lister for first sales
          created-at: block-height,
          expires-at: expires-at,
          category: category
        }
      )
      
      ;; Add to category if specified
      (match category
        cat (add-to-category listing-id cat)
        true
      )
      
      ;; Increment listing ID counter
      (var-set next-listing-id (+ listing-id u1))
      
      (ok listing-id)
    )
  )
)

;; Update listing price
(define-public (update-listing-price (listing-id uint) (new-price uint))
  (let (
    (listing (unwrap! (map-get? listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
  )
    (begin
      ;; Verify sender is the seller
      (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
      ;; Verify new price is valid
      (asserts! (> new-price u0) ERR-INVALID-PRICE)
      
      ;; Update the listing with new price
      (map-set listings
        { listing-id: listing-id }
        (merge listing { price: new-price })
      )
      
      (ok true)
    )
  )
)

;; Cancel a listing
(define-public (cancel-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
  )
    (begin
      ;; Verify sender is the seller
      (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
      
      ;; Return NFT to seller
      (try! (as-contract (contract-call? 
                          (get nft-contract listing) 
                          transfer 
                          (get token-id listing) 
                          tx-sender 
                          (get seller listing))))
      
      ;; Remove from category if applicable
      (match (get category listing)
        cat (remove-from-category listing-id cat)
        true
      )
      
      ;; Remove the listing
      (map-delete listings { listing-id: listing-id })
      
      (ok true)
    )
  )
)

;; Purchase a listed artwork
(define-public (purchase (listing-id uint))
  (let (
    (listing (unwrap! (map-get? listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
    (price (get price listing))
    (seller (get seller listing))
    (nft-contract (get nft-contract listing))
    (token-id (get token-id listing))
    (royalty-percent (get royalty-percent listing))
    (original-artist (get original-artist listing))
    (expires-at (get expires-at listing))
  )
    (begin
      ;; Check that listing hasn't expired if an expiration was set
      (asserts! (match expires-at
                  exp-height (< block-height exp-height)
                  true)
               ERR-LISTING-EXPIRED)
      
      ;; Process payment and distribute funds
      (try! (distribute-payment price seller original-artist royalty-percent))
      
      ;; Transfer NFT to buyer
      (try! (as-contract (contract-call? nft-contract transfer token-id tx-sender tx-sender)))
      
      ;; Record the sale
      (try! (record-sale listing-id listing (calculate-royalty price royalty-percent)))
      
      ;; Remove from category if applicable
      (match (get category listing)
        cat (remove-from-category listing-id cat)
        true
      )
      
      ;; Remove the listing
      (map-delete listings { listing-id: listing-id })
      
      (ok true)
    )
  )
)

;; Add listing to featured collection (admin only)
(define-public (add-to-featured-collection (listing-id uint) (collection-name (string-ascii 50)) (featured-until uint))
  (let (
    (current-collection (default-to { listing-ids: (list), featured-until: u0 }
                                     (map-get? featured-collections { collection-name: collection-name })))
    (current-list (get listing-ids current-collection))
  )
    (begin
      (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
      (asserts! (map-get? listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND)
      
      (map-set featured-collections
        { collection-name: collection-name }
        { 
          listing-ids: (append current-list listing-id), 
          featured-until: featured-until 
        }
      )
      
      (ok true)
    )
  )
)

;; Read-only functions

;; Check if user is owner of a specific NFT
(define-read-only (is-owner (nft-contract principal) (token-id uint) (address principal))
  (contract-call? nft-contract get-owner token-id)
)

;; Get listing details
(define-read-only (get-listing (listing-id uint))
  (map-get? listings { listing-id: listing-id })
)

;; Get all listings by a seller
(define-read-only (get-listings-by-seller (seller principal))
  (filter listings seller-listing-filter)
)

(define-read-only (seller-listing-filter (listing { listing-id: uint }))
  (let ((listing-data (unwrap! (map-get? listings listing) false)))
    (is-eq (get seller listing-data) tx-sender)
  )
)

;; Get all listings in a category
(define-read-only (get-listings-by-category (category (string-ascii 20)))
  (let (
    (category-data (default-to { listing-ids: (list) } (map-get? artwork-by-category { category: category })))
  )
    (get listing-ids category-data)
  )
)

;; Get featured collection
(define-read-only (get-featured-collection (collection-name (string-ascii 50)))
  (map-get? featured-collections { collection-name: collection-name })
)

;; Get active featured collections
(define-read-only (get-active-featured-collections)
  (filter featured-collections active-collection-filter)
)

(define-read-only (active-collection-filter (collection { collection-name: (string-ascii 50) }))
  (let ((collection-data (unwrap! (map-get? featured-collections collection) false)))
    (>= (get featured-until collection-data) block-height)
  )
)

;; Get sale history for a listing
(define-read-only (get-sales-history (listing-id uint))
  (let (
    (sales-count (default-to u0 (map-get? listing-sales-count { listing-id: listing-id })))
  )
    (filter sales-history (history-filter-by-listing listing-id))
  )
)

(define-read-only (history-filter-by-listing (listing-id uint) (sale { listing-id: uint, sale-index: uint }))
  (is-eq (get listing-id sale) listing-id)
)

;; Check if contract is supported
(define-read-only (is-contract-supported (contract principal))
  (is-supported-contract contract)
)