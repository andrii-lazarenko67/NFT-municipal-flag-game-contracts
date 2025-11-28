// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title MunicipalFlagNFT
 * @dev ERC721 contract for Municipal Flag NFT Game
 *
 * MULTI-NFT FEATURE DOCUMENTATION:
 * ================================
 * This contract supports flags that require multiple NFTs to obtain.
 *
 * Design Decision: We implemented "grouped NFTs" (Solution B) rather than
 * fragmenting NFTs. This means:
 * - nftsRequired=1: Standard flag, user claims 1 first NFT and purchases 1 second NFT
 * - nftsRequired=3: Grouped flag, user must claim/purchase 3x the normal amount
 *
 * The grouping is handled by:
 * 1. Storing nftsRequired in the FlagPair struct
 * 2. Minting multiple tokens in a single transaction (claimFirstNFTs, purchaseSecondNFTs)
 * 3. Total price = basePrice * nftsRequired
 *
 * Why Grouping over Fragmentation:
 * - Simpler implementation (no fractional ownership)
 * - Standard ERC721 compatibility (each token is whole)
 * - Clear user experience (you need X NFTs to complete)
 *
 * Each flag has a pair of NFTs:
 * - First NFT(s): Free to claim (shows interest)
 * - Second NFT(s): Purchased to complete the pair
 *
 * Flag Categories:
 * - Standard (0): No discounts
 * - Plus (1): 50% discount on future Standard purchases
 * - Premium (2): 75% permanent discount on Standard purchases
 */
contract MunicipalFlagNFT is ERC721, ERC721Enumerable, ERC721URIStorage, Ownable {
    using Strings for uint256;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    uint256 private _tokenIdCounter;
    string private _baseTokenURI;

    // Flag categories
    uint8 public constant CATEGORY_STANDARD = 0;
    uint8 public constant CATEGORY_PLUS = 1;
    uint8 public constant CATEGORY_PREMIUM = 2;

    // Discount percentages (in basis points, 10000 = 100%)
    uint256 public constant PLUS_DISCOUNT = 5000;     // 50%
    uint256 public constant PREMIUM_DISCOUNT = 7500;  // 75%

    /**
     * @dev Flag pair structure with multi-NFT support
     *
     * MULTI-NFT FIELDS:
     * - nftsRequired: Number of NFTs needed to obtain this flag (1 = single, 3 = grouped)
     * - firstTokenIds: Array of token IDs for first NFTs (length = nftsRequired)
     * - secondTokenIds: Array of token IDs for second NFTs (length = nftsRequired)
     * - firstMintedCount: How many first NFTs have been claimed
     * - secondMintedCount: How many second NFTs have been purchased
     */
    struct FlagPair {
        uint256 flagId;
        uint256 firstTokenId;      // First token ID (for single NFT compatibility)
        uint256 secondTokenId;     // Second token ID (for single NFT compatibility)
        bool firstMinted;          // All first NFTs claimed
        bool secondMinted;         // All second NFTs purchased
        bool pairComplete;
        uint8 category;
        uint256 price;             // Price per NFT
        uint8 nftsRequired;        // MULTI-NFT: Number of NFTs required (1 or 3)
        uint8 firstMintedCount;    // MULTI-NFT: Count of first NFTs claimed
        uint8 secondMintedCount;   // MULTI-NFT: Count of second NFTs purchased
    }

    // Mappings
    mapping(uint256 => FlagPair) public flagPairs;
    mapping(uint256 => uint256) public tokenToFlag;
    mapping(address => bool) public hasPlus;
    mapping(address => bool) public hasPremium;

    // MULTI-NFT: Track all token IDs for each flag
    mapping(uint256 => uint256[]) public flagFirstTokenIds;
    mapping(uint256 => uint256[]) public flagSecondTokenIds;

    // Track registered flags
    uint256[] private _registeredFlagIds;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event FlagRegistered(
        uint256 indexed flagId,
        uint8 category,
        uint256 price,
        uint8 nftsRequired  // MULTI-NFT: Added nftsRequired to event
    );

    event FirstNFTClaimed(
        uint256 indexed flagId,
        uint256 indexed tokenId,
        address indexed claimer,
        uint8 claimCount  // MULTI-NFT: Which claim number this is (1, 2, or 3)
    );

    event SecondNFTPurchased(
        uint256 indexed flagId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 pricePaid,
        uint8 purchaseCount  // MULTI-NFT: Which purchase number this is
    );

    event PairCompleted(uint256 indexed flagId);

    event BaseURIUpdated(string newBaseURI);

    event Withdrawal(address indexed to, uint256 amount);

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        string memory baseURI
    ) ERC721("Municipal Flag NFT", "MFLAG") Ownable(msg.sender) {
        _baseTokenURI = baseURI;
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    /**
     * @dev Register a new flag for the game with multi-NFT support
     * @param flagId Unique identifier for the flag
     * @param category Flag category (0=Standard, 1=Plus, 2=Premium)
     * @param price Price in wei for each second NFT
     * @param nftsRequired Number of NFTs required to obtain this flag (1 or 3)
     *
     * MULTI-NFT DOCUMENTATION:
     * When nftsRequired > 1, the user must:
     * 1. Claim nftsRequired first NFTs (free)
     * 2. Purchase nftsRequired second NFTs (price each)
     * Total cost = price * nftsRequired
     */
    function registerFlag(
        uint256 flagId,
        uint8 category,
        uint256 price,
        uint8 nftsRequired
    ) external onlyOwner {
        require(flagPairs[flagId].flagId == 0, "Flag already registered");
        require(category <= CATEGORY_PREMIUM, "Invalid category");
        require(price > 0, "Price must be greater than 0");
        require(nftsRequired > 0 && nftsRequired <= 10, "NFTs required must be 1-10");

        flagPairs[flagId] = FlagPair({
            flagId: flagId,
            firstTokenId: 0,
            secondTokenId: 0,
            firstMinted: false,
            secondMinted: false,
            pairComplete: false,
            category: category,
            price: price,
            nftsRequired: nftsRequired,
            firstMintedCount: 0,
            secondMintedCount: 0
        });

        _registeredFlagIds.push(flagId);

        emit FlagRegistered(flagId, category, price, nftsRequired);
    }

    /**
     * @dev Register a flag with default nftsRequired=1 (backward compatible)
     */
    function registerFlagSimple(
        uint256 flagId,
        uint8 category,
        uint256 price
    ) external onlyOwner {
        require(flagPairs[flagId].flagId == 0, "Flag already registered");
        require(category <= CATEGORY_PREMIUM, "Invalid category");
        require(price > 0, "Price must be greater than 0");

        flagPairs[flagId] = FlagPair({
            flagId: flagId,
            firstTokenId: 0,
            secondTokenId: 0,
            firstMinted: false,
            secondMinted: false,
            pairComplete: false,
            category: category,
            price: price,
            nftsRequired: 1,
            firstMintedCount: 0,
            secondMintedCount: 0
        });

        _registeredFlagIds.push(flagId);

        emit FlagRegistered(flagId, category, price, 1);
    }

    /**
     * @dev Batch register multiple flags with multi-NFT support
     * @param flagIds Array of flag IDs
     * @param categories Array of categories
     * @param prices Array of prices
     * @param nftsRequiredArr Array of NFTs required for each flag
     */
    function batchRegisterFlags(
        uint256[] calldata flagIds,
        uint8[] calldata categories,
        uint256[] calldata prices,
        uint8[] calldata nftsRequiredArr
    ) external onlyOwner {
        require(
            flagIds.length == categories.length &&
            flagIds.length == prices.length &&
            flagIds.length == nftsRequiredArr.length,
            "Arrays length mismatch"
        );

        for (uint256 i = 0; i < flagIds.length; i++) {
            require(flagPairs[flagIds[i]].flagId == 0, "Flag already registered");
            require(categories[i] <= CATEGORY_PREMIUM, "Invalid category");
            require(prices[i] > 0, "Price must be greater than 0");
            require(nftsRequiredArr[i] > 0 && nftsRequiredArr[i] <= 10, "NFTs required must be 1-10");

            flagPairs[flagIds[i]] = FlagPair({
                flagId: flagIds[i],
                firstTokenId: 0,
                secondTokenId: 0,
                firstMinted: false,
                secondMinted: false,
                pairComplete: false,
                category: categories[i],
                price: prices[i],
                nftsRequired: nftsRequiredArr[i],
                firstMintedCount: 0,
                secondMintedCount: 0
            });

            _registeredFlagIds.push(flagIds[i]);

            emit FlagRegistered(flagIds[i], categories[i], prices[i], nftsRequiredArr[i]);
        }
    }

    /**
     * @dev Update the base URI for token metadata
     * @param newBaseURI New base URI
     */
    function setBaseURI(string memory newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /**
     * @dev Withdraw contract balance
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");

        emit Withdrawal(owner(), balance);
    }

    // =============================================================================
    // PUBLIC FUNCTIONS - MULTI-NFT SUPPORT
    // =============================================================================

    /**
     * @dev Claim the first NFT(s) of a flag pair (free)
     * @param flagId The flag ID to claim
     *
     * MULTI-NFT BEHAVIOR:
     * - For single NFT flags (nftsRequired=1): Claims 1 NFT
     * - For grouped NFT flags (nftsRequired=3): Claims all 3 NFTs in one transaction
     *
     * All first NFTs must be claimed before any second NFTs can be purchased.
     */
    function claimFirstNFT(uint256 flagId) external {
        FlagPair storage pair = flagPairs[flagId];

        require(pair.flagId != 0, "Flag not registered");
        require(!pair.firstMinted, "First NFT(s) already claimed");

        // MULTI-NFT: Mint all required first NFTs
        for (uint8 i = 0; i < pair.nftsRequired; i++) {
            _tokenIdCounter++;
            uint256 newTokenId = _tokenIdCounter;

            _safeMint(msg.sender, newTokenId);
            tokenToFlag[newTokenId] = flagId;
            flagFirstTokenIds[flagId].push(newTokenId);

            // Store first token ID for backward compatibility
            if (i == 0) {
                pair.firstTokenId = newTokenId;
            }

            pair.firstMintedCount++;
            emit FirstNFTClaimed(flagId, newTokenId, msg.sender, i + 1);
        }

        pair.firstMinted = true;
    }

    /**
     * @dev Purchase the second NFT(s) of a flag pair
     * @param flagId The flag ID to purchase
     *
     * MULTI-NFT BEHAVIOR:
     * - For single NFT flags: Purchases 1 NFT at base price
     * - For grouped NFT flags: Purchases all NFTs, total price = basePrice * nftsRequired
     *
     * PRICING:
     * Total cost = getPriceWithDiscount(flagId, buyer) * nftsRequired
     */
    function purchaseSecondNFT(uint256 flagId) external payable {
        FlagPair storage pair = flagPairs[flagId];

        require(pair.flagId != 0, "Flag not registered");
        require(pair.firstMinted, "First NFT(s) must be claimed first");
        require(!pair.secondMinted, "Second NFT(s) already purchased");

        // MULTI-NFT: Calculate total price for all required NFTs
        uint256 pricePerNFT = getPriceWithDiscount(flagId, msg.sender);
        uint256 totalPrice = pricePerNFT * pair.nftsRequired;
        require(msg.value >= totalPrice, "Insufficient payment");

        // MULTI-NFT: Mint all required second NFTs
        for (uint8 i = 0; i < pair.nftsRequired; i++) {
            _tokenIdCounter++;
            uint256 newTokenId = _tokenIdCounter;

            _safeMint(msg.sender, newTokenId);
            tokenToFlag[newTokenId] = flagId;
            flagSecondTokenIds[flagId].push(newTokenId);

            // Store first second token ID for backward compatibility
            if (i == 0) {
                pair.secondTokenId = newTokenId;
            }

            pair.secondMintedCount++;
            emit SecondNFTPurchased(flagId, newTokenId, msg.sender, pricePerNFT, i + 1);
        }

        pair.secondMinted = true;
        pair.pairComplete = true;

        // Update discount eligibility based on category
        if (pair.category == CATEGORY_PLUS && !hasPlus[msg.sender]) {
            hasPlus[msg.sender] = true;
        } else if (pair.category == CATEGORY_PREMIUM && !hasPremium[msg.sender]) {
            hasPremium[msg.sender] = true;
        }

        // Refund excess payment
        if (msg.value > totalPrice) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - totalPrice}("");
            require(refundSuccess, "Refund failed");
        }

        emit PairCompleted(flagId);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /**
     * @dev Get flag pair information
     * @param flagId The flag ID
     * @return FlagPair struct
     */
    function getFlagPair(uint256 flagId) external view returns (FlagPair memory) {
        return flagPairs[flagId];
    }

    /**
     * @dev Get all first token IDs for a flag (MULTI-NFT)
     * @param flagId The flag ID
     * @return Array of token IDs
     */
    function getFirstTokenIds(uint256 flagId) external view returns (uint256[] memory) {
        return flagFirstTokenIds[flagId];
    }

    /**
     * @dev Get all second token IDs for a flag (MULTI-NFT)
     * @param flagId The flag ID
     * @return Array of token IDs
     */
    function getSecondTokenIds(uint256 flagId) external view returns (uint256[] memory) {
        return flagSecondTokenIds[flagId];
    }

    /**
     * @dev Get number of NFTs required for a flag (MULTI-NFT)
     * @param flagId The flag ID
     * @return Number of NFTs required
     */
    function getNftsRequired(uint256 flagId) external view returns (uint8) {
        return flagPairs[flagId].nftsRequired;
    }

    /**
     * @dev Calculate total price for all NFTs with discount
     * @param flagId The flag ID
     * @param buyer The buyer address
     * @return Total price for all required NFTs after discount
     */
    function getTotalPriceWithDiscount(
        uint256 flagId,
        address buyer
    ) external view returns (uint256) {
        FlagPair memory pair = flagPairs[flagId];
        require(pair.flagId != 0, "Flag not registered");
        return getPriceWithDiscount(flagId, buyer) * pair.nftsRequired;
    }

    /**
     * @dev Calculate price per NFT with discount for a buyer
     * @param flagId The flag ID
     * @param buyer The buyer address
     * @return Final price per NFT after discount
     */
    function getPriceWithDiscount(
        uint256 flagId,
        address buyer
    ) public view returns (uint256) {
        FlagPair memory pair = flagPairs[flagId];
        require(pair.flagId != 0, "Flag not registered");

        uint256 basePrice = pair.price;

        // Only apply discounts to Standard category flags
        if (pair.category == CATEGORY_STANDARD) {
            if (hasPremium[buyer]) {
                // 75% discount
                return basePrice - (basePrice * PREMIUM_DISCOUNT / 10000);
            } else if (hasPlus[buyer]) {
                // 50% discount
                return basePrice - (basePrice * PLUS_DISCOUNT / 10000);
            }
        }

        return basePrice;
    }

    /**
     * @dev Get total number of registered flags
     * @return Total count
     */
    function getTotalRegisteredFlags() external view returns (uint256) {
        return _registeredFlagIds.length;
    }

    /**
     * @dev Get all registered flag IDs
     * @return Array of flag IDs
     */
    function getRegisteredFlagIds() external view returns (uint256[] memory) {
        return _registeredFlagIds;
    }

    /**
     * @dev Check if user has Plus discount
     * @param user Address to check
     * @return bool
     */
    function userHasPlus(address user) external view returns (bool) {
        return hasPlus[user];
    }

    /**
     * @dev Check if user has Premium discount
     * @param user Address to check
     * @return bool
     */
    function userHasPremium(address user) external view returns (bool) {
        return hasPremium[user];
    }

    /**
     * @dev Get the flag ID for a token
     * @param tokenId The token ID
     * @return Flag ID
     */
    function getFlagIdForToken(uint256 tokenId) external view returns (uint256) {
        return tokenToFlag[tokenId];
    }

    // =============================================================================
    // OVERRIDES
    // =============================================================================

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");

        string memory baseURI = _baseURI();
        return bytes(baseURI).length > 0
            ? string(abi.encodePacked(baseURI, tokenId.toString(), ".json"))
            : "";
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
