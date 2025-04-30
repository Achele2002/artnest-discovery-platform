;; ArtNest NFT Contract
;; This contract defines and manages the NFTs that represent artwork on the ArtNest platform.
;; It allows artists to mint new NFTs with metadata about their artwork, set royalty percentages,
;; and transfer ownership when artworks are sold. The contract maintains the complete provenance
;; history of each artwork and ensures that only the current owner can transfer an artwork.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-ARTIST (err u101))
(define-constant ERR-INVALID-ARTWORK-ID (err u102))
(define-constant ERR-ARTWORK-EXISTS (err u103))
(define-constant ERR-NOT-OWNER (err u104))
(define-constant ERR-INVALID-ROYALTY (err u105))
(define-constant ERR-INVALID-DATA (err u106))
(define-constant ERR-TRANSFER-FAILED (err u107))
(define-constant ERR-VERIFIED-ARTIST-CHECK-FAILED (err u108))
(define-constant ERR-NOT-ADMIN (err u109))

;; Constants
(define-constant ADMIN-ADDRESS tx-sender) ;; Set contract deployer as admin
(define-constant MAX-ROYALTY-PERCENTAGE u30) ;; 30% maximum royalty
(define-constant MIN-ROYALTY-PERCENTAGE u0) ;; 0% minimum royalty

;; Data Maps and Variables
;; Track the last artwork ID assigned
(define-data-var last-artwork-id uint u0)

;; Store artwork metadata
(define-map artworks
  { artwork-id: uint }
  {
    title: (string-utf8 100),
    description: (string-utf8 500),
    creation-date: uint,
    medium: (string-utf8 50),
    artist: principal,
    owner: principal,
    royalty-percentage: uint,
    uri: (string-utf8 256),
    verified: bool
  }
)

;; Track if an address is a verified artist
(define-map verified-artists
  { artist: principal }
  { verified: bool }
)

;; Track the ownership history of each artwork
(define-map artwork-provenance
  { artwork-id: uint, owner-index: uint }
  {
    owner: principal,
    acquired-at: uint,
    transaction-id: (optional (buff 32))
  }
)

;; Track how many owners an artwork has had
(define-map artwork-owner-count
  { artwork-id: uint }
  { count: uint }
)

;; Track artworks owned by a specific address
(define-map owned-artworks
  { owner: principal }
  { artwork-ids: (list 1000 uint) }
)

;; Track artworks created by a specific artist
(define-map artist-creations
  { artist: principal }
  { artwork-ids: (list 1000 uint) }
)

;; Private functions

;; Generate a new artwork ID
(define-private (generate-artwork-id)
  (let
    ((new-id (+ (var-get last-artwork-id) u1)))
    (var-set last-artwork-id new-id)
    new-id
  )
)

;; Add artwork to the list of owned artworks
(define-private (add-owned-artwork (owner principal) (artwork-id uint))
  (let
    ((current-owned (default-to { artwork-ids: (list) } (map-get? owned-artworks { owner: owner }))))
    (map-set owned-artworks
      { owner: owner }
      { artwork-ids: (append (get artwork-ids current-owned) artwork-id) }
    )
  )
)

;; Remove artwork from the list of owned artworks
(define-private (remove-owned-artwork (owner principal) (artwork-id uint))
  (let
    ((current-owned (default-to { artwork-ids: (list) } (map-get? owned-artworks { owner: owner }))))
    (map-set owned-artworks
      { owner: owner }
      { artwork-ids: (filter remove-artwork-id-filter (get artwork-ids current-owned)) }
    )
  )
)

;; Helper function for filtering out an artwork ID
(define-private (remove-artwork-id-filter (id uint))
  (not (is-eq id id))
)

;; Add artwork to the list of artist creations
(define-private (add-artist-creation (artist principal) (artwork-id uint))
  (let
    ((current-creations (default-to { artwork-ids: (list) } (map-get? artist-creations { artist: artist }))))
    (map-set artist-creations
      { artist: artist }
      { artwork-ids: (append (get artwork-ids current-creations) artwork-id) }
    )
  )
)

;; Record the ownership of an artwork in the provenance history
(define-private (record-ownership (artwork-id uint) (owner principal) (tx-id (optional (buff 32))))
  (let
    ((current-count (default-to { count: u0 } (map-get? artwork-owner-count { artwork-id: artwork-id })))
     (new-count (+ (get count current-count) u1)))
    
    ;; Update the owner count
    (map-set artwork-owner-count
      { artwork-id: artwork-id }
      { count: new-count }
    )
    
    ;; Record the new ownership
    (map-set artwork-provenance
      { artwork-id: artwork-id, owner-index: new-count }
      {
        owner: owner,
        acquired-at: block-height,
        transaction-id: tx-id
      }
    )
  )
)

;; Transfer ownership of an artwork from one address to another
(define-private (transfer-ownership (artwork-id uint) (sender principal) (recipient principal))
  (let
    ((artwork (map-get? artworks { artwork-id: artwork-id })))
    
    (asserts! (is-some artwork) ERR-INVALID-ARTWORK-ID)
    (asserts! (is-eq (get owner (unwrap-panic artwork)) sender) ERR-NOT-OWNER)
    
    ;; Update the artwork owner
    (map-set artworks
      { artwork-id: artwork-id }
      (merge (unwrap-panic artwork) { owner: recipient })
    )
    
    ;; Update ownership lists
    (remove-owned-artwork sender artwork-id)
    (add-owned-artwork recipient artwork-id)
    
    ;; Record the ownership change in provenance
    (record-ownership artwork-id recipient (some tx-hash))
    
    (ok true)
  )
)

;; Public Functions

;; Register as a verified artist (admin only)
(define-public (verify-artist (artist principal))
  (begin
    (asserts! (is-eq tx-sender ADMIN-ADDRESS) ERR-NOT-ADMIN)
    (map-set verified-artists
      { artist: artist }
      { verified: true }
    )
    (ok true)
  )
)

;; Check if an address is a verified artist
(define-read-only (is-verified-artist (artist principal))
  (default-to false (get verified: (map-get? verified-artists { artist: artist })))
)

;; Mint a new artwork NFT
(define-public (mint-artwork
  (title (string-utf8 100))
  (description (string-utf8 500))
  (creation-date uint)
  (medium (string-utf8 50))
  (royalty-percentage uint)
  (uri (string-utf8 256)))
  
  (let
    ((artist tx-sender)
     (artwork-id (generate-artwork-id)))
    
    ;; Check if royalty percentage is valid
    (asserts! (and (>= royalty-percentage MIN-ROYALTY-PERCENTAGE) 
                  (<= royalty-percentage MAX-ROYALTY-PERCENTAGE)) 
              ERR-INVALID-ROYALTY)
    
    ;; Check if title is not empty
    (asserts! (> (len title) u0) ERR-INVALID-DATA)
    
    ;; Create the artwork record
    (map-set artworks
      { artwork-id: artwork-id }
      {
        title: title,
        description: description,
        creation-date: creation-date,
        medium: medium,
        artist: artist,
        owner: artist, ;; Initially, the artist owns the artwork
        royalty-percentage: royalty-percentage,
        uri: uri,
        verified: (is-verified-artist artist)
      }
    )
    
    ;; Add to artist's creations
    (add-artist-creation artist artwork-id)
    
    ;; Add to artist's owned artworks
    (add-owned-artwork artist artwork-id)
    
    ;; Record initial ownership
    (record-ownership artwork-id artist none)
    
    (ok artwork-id)
  )
)

;; Transfer an artwork to a new owner
(define-public (transfer (artwork-id uint) (recipient principal))
  (let
    ((sender tx-sender))
    
    (asserts! (not (is-eq sender recipient)) ERR-INVALID-DATA)
    (transfer-ownership artwork-id sender recipient)
  )
)

;; Update artwork metadata (only by artist)
(define-public (update-artwork-metadata
  (artwork-id uint)
  (title (string-utf8 100))
  (description (string-utf8 500))
  (medium (string-utf8 50))
  (uri (string-utf8 256)))
  
  (let
    ((artwork (map-get? artworks { artwork-id: artwork-id })))
    
    ;; Check if artwork exists
    (asserts! (is-some artwork) ERR-INVALID-ARTWORK-ID)
    
    ;; Check if caller is the artist
    (asserts! (is-eq (get artist (unwrap-panic artwork)) tx-sender) ERR-NOT-ARTIST)
    
    ;; Update the metadata
    (map-set artworks
      { artwork-id: artwork-id }
      (merge (unwrap-panic artwork) 
        {
          title: title,
          description: description,
          medium: medium,
          uri: uri
        }
      )
    )
    
    (ok true)
  )
)

;; Update royalty percentage (only by artist)
(define-public (update-royalty-percentage (artwork-id uint) (royalty-percentage uint))
  (let
    ((artwork (map-get? artworks { artwork-id: artwork-id })))
    
    ;; Check if artwork exists
    (asserts! (is-some artwork) ERR-INVALID-ARTWORK-ID)
    
    ;; Check if caller is the artist
    (asserts! (is-eq (get artist (unwrap-panic artwork)) tx-sender) ERR-NOT-ARTIST)
    
    ;; Check if royalty percentage is valid
    (asserts! (and (>= royalty-percentage MIN-ROYALTY-PERCENTAGE) 
                  (<= royalty-percentage MAX-ROYALTY-PERCENTAGE)) 
              ERR-INVALID-ROYALTY)
    
    ;; Update the royalty
    (map-set artworks
      { artwork-id: artwork-id }
      (merge (unwrap-panic artwork) { royalty-percentage: royalty-percentage })
    )
    
    (ok true)
  )
)

;; Read-only Functions

;; Get artwork details
(define-read-only (get-artwork (artwork-id uint))
  (map-get? artworks { artwork-id: artwork-id })
)

;; Get artwork provenance history
(define-read-only (get-artwork-provenance (artwork-id uint))
  (let
    ((owner-count (default-to { count: u0 } (map-get? artwork-owner-count { artwork-id: artwork-id }))))
    (ok {
      artwork-id: artwork-id,
      owner-count: (get count owner-count)
    })
  )
)

;; Get a specific ownership record from provenance
(define-read-only (get-ownership-record (artwork-id uint) (owner-index uint))
  (map-get? artwork-provenance { artwork-id: artwork-id, owner-index: owner-index })
)

;; Get all artworks owned by an address
(define-read-only (get-owned-artworks (owner principal))
  (default-to { artwork-ids: (list) } (map-get? owned-artworks { owner: owner }))
)

;; Get all artworks created by an artist
(define-read-only (get-artist-creations (artist principal))
  (default-to { artwork-ids: (list) } (map-get? artist-creations { artist: artist }))
)

;; Check if an address owns a specific artwork
(define-read-only (is-owner (artwork-id uint) (address principal))
  (let
    ((artwork (map-get? artworks { artwork-id: artwork-id })))
    (and (is-some artwork) (is-eq (get owner (unwrap-panic artwork)) address))
  )
)

;; Get the royalty percentage for an artwork
(define-read-only (get-royalty-percentage (artwork-id uint))
  (let
    ((artwork (map-get? artworks { artwork-id: artwork-id })))
    (if (is-some artwork)
        (ok (get royalty-percentage (unwrap-panic artwork)))
        ERR-INVALID-ARTWORK-ID
    )
  )
)

;; Get total number of artworks minted
(define-read-only (get-total-artworks)
  (var-get last-artwork-id)
)