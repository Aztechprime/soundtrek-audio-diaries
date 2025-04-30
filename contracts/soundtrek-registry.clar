;; soundtrek-registry
;; 
;; This contract serves as the central registry for all SoundTrek audio content.
;; It manages audio diary registration, ownership tracking, geographic indexing,
;; and content discovery. It allows users to find content by location, create
;; curated paths ("treks"), and maintains popularity metrics.
;; 
;; The contract ensures proper ownership attribution and implements authorization
;; checks for all state-changing operations.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-AUDIO-EXISTS (err u101))
(define-constant ERR-AUDIO-NOT-FOUND (err u102))
(define-constant ERR-INVALID-LOCATION (err u103))
(define-constant ERR-TREK-EXISTS (err u104))
(define-constant ERR-TREK-NOT-FOUND (err u105))
(define-constant ERR-AUDIO-NOT-IN-TREK (err u106))
(define-constant ERR-INSUFFICIENT-FUNDS (err u107))
(define-constant ERR-TRANSFER-FAILED (err u108))
(define-constant ERR-INVALID-TAG (err u109))
(define-constant ERR-MAX-TAGS-REACHED (err u110))

;; Data maps and vars

;; Main registry of audio content
(define-map audio-content
  { audio-id: uint }
  {
    owner: principal,
    title: (string-ascii 64),
    description: (string-utf8 500),
    creation-time: uint,
    location: {lat: int, lng: int},  ;; Using integers to represent coordinates with precision
    ipfs-hash: (string-ascii 64),    ;; Reference to audio content stored on IPFS
    is-private: bool,
    price: uint,                     ;; In microSTX, 0 for free content
    play-count: uint,
    tags: (list 10 (string-ascii 20))
  }
)

;; Secondary index: location to audio mappings
;; We use string keys with "lat-lng" format (e.g., "40723196--73989309" for 40.723196, -73.989309)
;; Integers are used to store coordinates with 6 decimal precision (lat*1000000, lng*1000000)
(define-map location-index
  { location-key: (string-ascii 32) }
  { audio-ids: (list 100 uint) }
)

;; User's created content
(define-map user-created-content
  { user: principal }
  { audio-ids: (list 500 uint) }
)

;; Trek definitions (curated paths)
(define-map treks
  { trek-id: uint }
  {
    owner: principal,
    title: (string-ascii 64),
    description: (string-utf8 500),
    audio-ids: (list 50 uint),
    creation-time: uint,
    tags: (list 10 (string-ascii 20)),
    play-count: uint
  }
)

;; User's created treks
(define-map user-created-treks
  { user: principal }
  { trek-ids: (list 100 uint) }
)

;; Track the total number of audio entries and treks for ID generation
(define-data-var next-audio-id uint u1)
(define-data-var next-trek-id uint u1)

;; Private functions

;; Check if the caller is the owner of the specified audio content
(define-private (is-audio-owner (audio-id uint))
  (let ((audio-data (unwrap! (map-get? audio-content {audio-id: audio-id}) false)))
    (is-eq tx-sender (get owner audio-data))
  )
)

;; Check if the caller is the owner of the specified trek
(define-private (is-trek-owner (trek-id uint))
  (let ((trek-data (unwrap! (map-get? treks {trek-id: trek-id}) false)))
    (is-eq tx-sender (get owner trek-data))
  )
)

;; Format location data for storage
(define-private (format-location-key (lat int) (lng int))
  (concat (concat (to-ascii lat) "--") (to-ascii lng))
)

;; Add an audio ID to a user's created content list
(define-private (add-to-user-content (user principal) (audio-id uint))
  (let ((current-content (default-to {audio-ids: (list)} (map-get? user-created-content {user: user}))))
    (map-set user-created-content
      {user: user}
      {audio-ids: (unwrap-panic (as-max-len? (append (get audio-ids current-content) audio-id) u500))}
    )
  )
)

;; Add an audio ID to a location index
(define-private (add-to-location-index (location-key (string-ascii 32)) (audio-id uint))
  (let ((current-index (default-to {audio-ids: (list)} (map-get? location-index {location-key: location-key}))))
    (map-set location-index
      {location-key: location-key}
      {audio-ids: (unwrap-panic (as-max-len? (append (get audio-ids current-index) audio-id) u100))}
    )
  )
)

;; Add a trek ID to a user's created treks list
(define-private (add-to-user-treks (user principal) (trek-id uint))
  (let ((current-treks (default-to {trek-ids: (list)} (map-get? user-created-treks {user: user}))))
    (map-set user-created-treks
      {user: user}
      {trek-ids: (unwrap-panic (as-max-len? (append (get trek-ids current-treks) trek-id) u100))}
    )
  )
)

;; Validate a set of tags
(define-private (validate-tags (tags (list 10 (string-ascii 20))))
  (< (len tags) u11)  ;; Maximum 10 tags
)

;; Public functions

;; Register new audio content
(define-public (register-audio
    (title (string-ascii 64))
    (description (string-utf8 500))
    (lat int)
    (lng int)
    (ipfs-hash (string-ascii 64))
    (is-private bool)
    (price uint)
    (tags (list 10 (string-ascii 20)))
  )
  (let 
    (
      (audio-id (var-get next-audio-id))
      (location-key (format-location-key lat lng))
    )
    
    ;; Validate input
    (asserts! (validate-tags tags) ERR-MAX-TAGS-REACHED)
    
    ;; Record the audio content
    (map-set audio-content
      {audio-id: audio-id}
      {
        owner: tx-sender,
        title: title,
        description: description,
        creation-time: block-height,
        location: {lat: lat, lng: lng},
        ipfs-hash: ipfs-hash,
        is-private: is-private,
        price: price,
        play-count: u0,
        tags: tags
      }
    )
    
    ;; Update the location index
    (add-to-location-index location-key audio-id)
    
    ;; Update user's content list
    (add-to-user-content tx-sender audio-id)
    
    ;; Increment the audio ID counter
    (var-set next-audio-id (+ audio-id u1))
    
    ;; Return the new audio ID
    (ok audio-id)
  )
)

;; Update existing audio content (owner only)
(define-public (update-audio
    (audio-id uint)
    (title (string-ascii 64))
    (description (string-utf8 500))
    (is-private bool)
    (price uint)
    (tags (list 10 (string-ascii 20)))
  )
  (let ((audio-data (unwrap! (map-get? audio-content {audio-id: audio-id}) ERR-AUDIO-NOT-FOUND)))
    ;; Ensure caller is the owner
    (asserts! (is-eq tx-sender (get owner audio-data)) ERR-NOT-AUTHORIZED)
    
    ;; Validate input
    (asserts! (validate-tags tags) ERR-MAX-TAGS-REACHED)
    
    ;; Update the record (note: location and IPFS hash cannot be changed)
    (map-set audio-content
      {audio-id: audio-id}
      (merge audio-data 
        {
          title: title,
          description: description,
          is-private: is-private,
          price: price,
          tags: tags
        }
      )
    )
    
    (ok true)
  )
)

;; Transfer ownership of audio content
(define-public (transfer-audio-ownership (audio-id uint) (new-owner principal))
  (let ((audio-data (unwrap! (map-get? audio-content {audio-id: audio-id}) ERR-AUDIO-NOT-FOUND)))
    ;; Ensure caller is the current owner
    (asserts! (is-eq tx-sender (get owner audio-data)) ERR-NOT-AUTHORIZED)
    
    ;; Update the owner
    (map-set audio-content
      {audio-id: audio-id}
      (merge audio-data {owner: new-owner})
    )
    
    ;; Add to new owner's content
    (add-to-user-content new-owner audio-id)
    
    (ok true)
  )
)

;; Create a trek (curated path)
(define-public (create-trek
    (title (string-ascii 64))
    (description (string-utf8 500))
    (audio-ids (list 50 uint))
    (tags (list 10 (string-ascii 20)))
  )
  (let 
    (
      (trek-id (var-get next-trek-id))
    )
    
    ;; Validate inputs
    (asserts! (validate-tags tags) ERR-MAX-TAGS-REACHED)
    
    ;; Create the trek
    (map-set treks
      {trek-id: trek-id}
      {
        owner: tx-sender,
        title: title,
        description: description,
        audio-ids: audio-ids,
        creation-time: block-height,
        tags: tags,
        play-count: u0
      }
    )
    
    ;; Add to user's treks
    (add-to-user-treks tx-sender trek-id)
    
    ;; Increment trek ID counter
    (var-set next-trek-id (+ trek-id u1))
    
    (ok trek-id)
  )
)

;; Update a trek (owner only)
(define-public (update-trek
    (trek-id uint)
    (title (string-ascii 64))
    (description (string-utf8 500))
    (audio-ids (list 50 uint))
    (tags (list 10 (string-ascii 20)))
  )
  (let ((trek-data (unwrap! (map-get? treks {trek-id: trek-id}) ERR-TREK-NOT-FOUND)))
    ;; Ensure caller is the owner
    (asserts! (is-eq tx-sender (get owner trek-data)) ERR-NOT-AUTHORIZED)
    
    ;; Validate input
    (asserts! (validate-tags tags) ERR-MAX-TAGS-REACHED)
    
    ;; Update the trek
    (map-set treks
      {trek-id: trek-id}
      (merge trek-data 
        {
          title: title,
          description: description,
          audio-ids: audio-ids,
          tags: tags
        }
      )
    )
    
    (ok true)
  )
)

;; Transfer ownership of a trek
(define-public (transfer-trek-ownership (trek-id uint) (new-owner principal))
  (let ((trek-data (unwrap! (map-get? treks {trek-id: trek-id}) ERR-TREK-NOT-FOUND)))
    ;; Ensure caller is the current owner
    (asserts! (is-eq tx-sender (get owner trek-data)) ERR-NOT-AUTHORIZED)
    
    ;; Update the owner
    (map-set treks
      {trek-id: trek-id}
      (merge trek-data {owner: new-owner})
    )
    
    ;; Add to new owner's treks
    (add-to-user-treks new-owner trek-id)
    
    (ok true)
  )
)

;; Record that a user played an audio content and handle payment if needed
(define-public (play-audio (audio-id uint))
  (let 
    (
      (audio-data (unwrap! (map-get? audio-content {audio-id: audio-id}) ERR-AUDIO-NOT-FOUND))
      (price (get price audio-data))
      (owner (get owner audio-data))
      (current-plays (get play-count audio-data))
    )
    
    ;; If content is paid, process payment
    (if (> price u0)
      (begin
        ;; Transfer payment from user to owner
        (unwrap! (stx-transfer? price tx-sender owner) ERR-TRANSFER-FAILED)
        ;; Continue execution
        true
      )
      true
    )
    
    ;; Update play count
    (map-set audio-content
      {audio-id: audio-id}
      (merge audio-data {play-count: (+ current-plays u1)})
    )
    
    (ok true)
  )
)

;; Record that a user followed a trek
(define-public (play-trek (trek-id uint))
  (let 
    (
      (trek-data (unwrap! (map-get? treks {trek-id: trek-id}) ERR-TREK-NOT-FOUND))
      (current-plays (get play-count trek-data))
    )
    
    ;; Update play count
    (map-set treks
      {trek-id: trek-id}
      (merge trek-data {play-count: (+ current-plays u1)})
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get audio content details
(define-read-only (get-audio-details (audio-id uint))
  (map-get? audio-content {audio-id: audio-id})
)

;; Find audio content by location
(define-read-only (find-audio-by-location (lat int) (lng int))
  (let ((location-key (format-location-key lat lng)))
    (map-get? location-index {location-key: location-key})
  )
)

;; Get trek details
(define-read-only (get-trek-details (trek-id uint))
  (map-get? treks {trek-id: trek-id})
)

;; Get audio content created by a specific user
(define-read-only (get-user-audio (user principal))
  (map-get? user-created-content {user: user})
)

;; Get treks created by a specific user
(define-read-only (get-user-treks (user principal))
  (map-get? user-created-treks {user: user})
)

;; Get total audio content count
(define-read-only (get-audio-count)
  (- (var-get next-audio-id) u1)
)

;; Get total trek count
(define-read-only (get-trek-count)
  (- (var-get next-trek-id) u1)
)