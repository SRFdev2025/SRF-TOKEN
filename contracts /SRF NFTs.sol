// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*
  SRF NFT / Fractional Asset Contract (ERC-1155)
  ✅ Compatible with OpenZeppelin 5.x
  ✅ ERC1155 (unique & fractional tokens)
  ✅ ERC2981 (royalties)
  ✅ Fees in SRF token (ERC20)
  ✅ Admin controls (update fees, treasury, etc.)
  ✅ Uses _update() override instead of _beforeTokenTransfer()
  ✅ Fixed constructor for Ownable v5
*/

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SRF_Asset_1155 is ERC1155, ERC1155Supply, ERC2981, Ownable, Pausable, ReentrancyGuard {
    struct TokenInfo {
        bool exists;
        uint256 maxSupply;
        uint256 mintFee;
        string uri;
    }

    mapping(uint256 => TokenInfo) public tokenInfo;

    address public treasury;
    address public saleContract;
    address public stakingContract;
    IERC20 public srfToken;
    address public usdt;

    event TokenCreated(uint256 indexed tokenId, uint256 maxSupply, uint256 mintFee, string uri);
    event Minted(address indexed minter, uint256 indexed tokenId, uint256 amount, uint256 totalFee);
    event BatchMinted(address indexed minter, uint256[] tokenIds, uint256[] amounts, uint256 totalFee);
    event TokenInfoUpdated(uint256 indexed tokenId);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SaleContractUpdated(address indexed oldAddr, address indexed newAddr);
    event StakingContractUpdated(address indexed oldAddr, address indexed newAddr);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event NativeRecovered(address indexed to, uint256 amount);
    event TokenBurned(address indexed operator, address indexed from, uint256 id, uint256 amount);

    modifier onlyOwnerOrSale() {
        require(owner() == msg.sender || saleContract == msg.sender, "Not owner or sale");
        _;
    }

    constructor(
        string memory _baseURI,
        address _srfToken,
        address _treasury,
        address _saleContract,
        address _stakingContract,
        address _usdt
    ) ERC1155(_baseURI) Ownable(msg.sender) { // 👈 important fix for OZ v5
        require(_srfToken != address(0), "SRF token zero");
        srfToken = IERC20(_srfToken);
        treasury = _treasury == address(0) ? msg.sender : _treasury;
        saleContract = _saleContract;
        stakingContract = _stakingContract;
        usdt = _usdt;
    }

    // -------------------------
    // Token management
    // -------------------------

    function createToken(
        uint256 tokenId,
        uint256 maxSupply,
        uint256 mintFee,
        string calldata uri_,
        address royaltyReceiver,
        uint96 royaltyFeeNumerator
    ) external onlyOwnerOrSale whenNotPaused {
        require(!tokenInfo[tokenId].exists, "token exists");
        require(maxSupply > 0, "maxSupply>0");

        if (royaltyReceiver != address(0) && royaltyFeeNumerator > 0) {
            require(royaltyFeeNumerator <= _feeDenominator(), "invalid royalty");
            _setTokenRoyalty(tokenId, royaltyReceiver, royaltyFeeNumerator);
        }

        tokenInfo[tokenId] = TokenInfo(true, maxSupply, mintFee, uri_);
        emit TokenCreated(tokenId, maxSupply, mintFee, uri_);
    }

    function updateTokenInfo(
        uint256 tokenId,
        uint256 maxSupply,
        uint256 mintFee,
        string calldata uri_
    ) external onlyOwnerOrSale {
        require(tokenInfo[tokenId].exists, "not exists");
        TokenInfo storage t = tokenInfo[tokenId];
        t.maxSupply = maxSupply;
        t.mintFee = mintFee;
        t.uri = uri_;
        emit TokenInfoUpdated(tokenId);
    }

    // -------------------------
    // Minting
    // -------------------------

    function mint(uint256 tokenId, uint256 amount) external nonReentrant whenNotPaused {
        require(tokenInfo[tokenId].exists, "not exist");
        require(amount > 0, "amount>0");

        TokenInfo storage t = tokenInfo[tokenId];
        require(totalSupply(tokenId) + amount <= t.maxSupply, "exceeds max supply");

        uint256 totalFee = t.mintFee * amount;
        if (totalFee > 0) {
            require(srfToken.transferFrom(msg.sender, treasury, totalFee), "SRF fee failed");
        }

        _mint(msg.sender, tokenId, amount, "");
        emit Minted(msg.sender, tokenId, amount, totalFee);
    }

    function batchMint(uint256[] calldata tokenIds, uint256[] calldata amounts) external nonReentrant whenNotPaused {
        require(tokenIds.length == amounts.length, "len mismatch");

        uint256 totalFee = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            TokenInfo storage t = tokenInfo[tokenIds[i]];
            require(t.exists, "token not exist");
            require(totalSupply(tokenIds[i]) + amounts[i] <= t.maxSupply, "exceeds supply");
            totalFee += t.mintFee * amounts[i];
        }

        if (totalFee > 0) {
            require(srfToken.transferFrom(msg.sender, treasury, totalFee), "SRF fee failed");
        }

        _mintBatch(msg.sender, tokenIds, amounts, "");
        emit BatchMinted(msg.sender, tokenIds, amounts, totalFee);
    }

    // -------------------------
    // Burn
    // -------------------------

    function burn(address from, uint256 id, uint256 amount) external whenNotPaused {
        require(
            from == msg.sender || isApprovedForAll(from, msg.sender) || owner() == msg.sender,
            "not authorized"
        );
        _burn(from, id, amount);
        emit TokenBurned(msg.sender, from, id, amount);
    }

    // -------------------------
    // Admin Config
    // -------------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "zero");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setSaleContract(address newSale) external onlyOwner {
        emit SaleContractUpdated(saleContract, newSale);
        saleContract = newSale;
    }

    function setStakingContract(address newStaking) external onlyOwner {
        emit StakingContractUpdated(stakingContract, newStaking);
        stakingContract = newStaking;
    }

    function setSRFToken(address newSRF) external onlyOwner {
        require(newSRF != address(0), "zero");
        srfToken = IERC20(newSRF);
    }

    function setUSDT(address newUSDT) external onlyOwner {
        usdt = newUSDT;
    }

    // royalties
    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 feeNumerator) external onlyOwnerOrSale {
        require(tokenInfo[tokenId].exists, "not exist");
        require(feeNumerator <= _feeDenominator(), "too high");
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        require(feeNumerator <= _feeDenominator(), "too high");
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function deleteDefaultRoyalty() external onlyOwner { _deleteDefaultRoyalty(); }

    // recover
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
        emit TokensRecovered(token, to, amount);
    }

    function recoverNative(address payable to) external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "no balance");
        to.transfer(bal);
        emit NativeRecovered(to, bal);
    }

    // -------------------------
    // Overrides (OZ v5 structure)
    // -------------------------

    function uri(uint256 tokenId) public view override returns (string memory) {
        if (tokenInfo[tokenId].exists && bytes(tokenInfo[tokenId].uri).length > 0)
            return tokenInfo[tokenId].uri;
        return super.uri(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ✅ new OZ v5 unified hook (_update replaces _beforeTokenTransfer)
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}
