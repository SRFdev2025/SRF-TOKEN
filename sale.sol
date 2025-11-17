/**
 *Submitted for verification at syriafreetoken By Masoud on 2024-10-04
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISRFToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SRFSale {
    address public owner;
    ISRFToken public token;
    IERC20 public usdt;
    uint256 public rate;       // عدد التوكنات لكل 1 ETH (POL/MATIC)
    uint256 public rateUSDT;   // عدد التوكنات لكل 1 USDT

    // محافظ التوزيع (معدلة كما طلبت)
    address public walletReconstruction = 0x3fF12833ce476253136c4E0BBD85935593B4e156;
    address public walletDevTeam       = 0xF976cC5f0a004570C9E0B3Da93410602CCfEd2d1;
    address public walletCommunity     = 0x773C267Ae0B44b6377EbFEF8f244eD9bf09A108A;
    address public walletMarketing     = 0xc1cCf8966882778Cd7030d760b7C8F7F9c909622;
    address public walletReserve       = 0x1909fD7f9872783f30Dac2a0Fe2DD291864CC293;
    address public walletLiquidity     = 0x28C18c113D819B0A4470dE81AC2a43882D37A431;

    event TokensPurchased(address indexed buyer, uint256 amount, string paymentToken);
    event TokensBurned(uint256 amount);

    constructor(address tokenAddress, address usdtAddress, uint256 _rate, uint256 _rateUSDT) {
        owner = msg.sender;
        token = ISRFToken(tokenAddress);
        usdt = IERC20(usdtAddress);
        rate = _rate;
        rateUSDT = _rateUSDT;
    }

    // --- Modifiers / Owner check simple ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // شراء باستخدام ETH (MATIC/POL)
    receive() external payable {
        buyTokens();
    }

    function buyTokens() public payable {
        require(msg.value > 0, "Send ETH to buy tokens");

        // حساب كمية التوكنات: افترضنا أن 'rate' هو tokens per 1 ETH (wei-handling expected off-chain)
        uint256 tokenAmount = msg.value * rate;

        // نقل التوكنات من عقد البيع إلى المشتري (توكن يجب أن يكون في رصيد العقد)
        require(token.transfer(msg.sender, tokenAmount), "Token transfer failed");

        emit TokensPurchased(msg.sender, tokenAmount, "ETH");

        _distributeETH(msg.value);
    }

    // شراء باستخدام USDT
    // usdtAmount يجب أن يكون بالوحدات الصحيحة (USDT: عادة 6 decimals)
    function buyTokensWithUSDT(uint256 usdtAmount) external {
        require(usdtAmount > 0, "Send USDT to buy tokens");

        // تحويل USDT من المشتري إلى العقد
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "USDT transfer failed");

        // حساب كمية التوكنات
        uint256 tokenAmount = usdtAmount * rateUSDT;

        // إرسال التوكنات للمشتري
        require(token.transfer(msg.sender, tokenAmount), "Token transfer failed");

        emit TokensPurchased(msg.sender, tokenAmount, "USDT");

        _distributeUSDT(usdtAmount);
    }

    // توزيع ETH/MATIC بالتقسيم المحدد
    function _distributeETH(uint256 amount) internal {
        payable(walletReconstruction).transfer((amount * 40) / 100);
        payable(walletDevTeam).transfer((amount * 15) / 100);
        payable(walletCommunity).transfer((amount * 10) / 100);
        payable(walletMarketing).transfer((amount * 10) / 100);
        payable(walletReserve).transfer((amount * 10) / 100);
        payable(walletLiquidity).transfer((amount * 15) / 100);
    }

    // توزيع USDT بالتقسيم نفسه
    function _distributeUSDT(uint256 amount) internal {
        require(usdt.transfer(walletReconstruction, (amount * 40) / 100), "USDT transfer fail");
        require(usdt.transfer(walletDevTeam,       (amount * 15) / 100), "USDT transfer fail");
        require(usdt.transfer(walletCommunity,     (amount * 10) / 100), "USDT transfer fail");
        require(usdt.transfer(walletMarketing,     (amount * 10) / 100), "USDT transfer fail");
        require(usdt.transfer(walletReserve,       (amount * 10) / 100), "USDT transfer fail");
        require(usdt.transfer(walletLiquidity,     (amount * 15) / 100), "USDT transfer fail");
    }

    // ضبط أسعار الصرف (يمكن للمالك فقط)
    function setRates(uint256 _rateETH, uint256 _rateUSDT) external onlyOwner {
        rate = _rateETH;
        rateUSDT = _rateUSDT;
    }

    // دالة حرق التوكن (تسحب من رصيد المالك أولاً)
    function burnTokens(uint256 amount) external onlyOwner {
        require(token.transferFrom(owner, address(this), amount), "Transfer to contract failed");
        token.burn(amount);
        emit TokensBurned(amount);
    }

    // --- وظائف لتعديل المحافظ بعد النشر إذا احتجت ---
    function setWallets(
        address _reconstruction,
        address _devTeam,
        address _community,
        address _marketing,
        address _reserve,
        address _liquidity
    ) external onlyOwner {
        require(_reconstruction != address(0), "zero addr");
        require(_devTeam != address(0), "zero addr");
        require(_community != address(0), "zero addr");
        require(_marketing != address(0), "zero addr");
        require(_reserve != address(0), "zero addr");
        require(_liquidity != address(0), "zero addr");

        walletReconstruction = _reconstruction;
        walletDevTeam = _devTeam;
        walletCommunity = _community;
        walletMarketing = _marketing;
        walletReserve = _reserve;
        walletLiquidity = _liquidity;
    }

    // للطوارئ: سحب ETH الموجود في العقد (لو تراكم لأي سبب)
    function emergencyWithdrawETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero addr");
        payable(to).transfer(amount);
    }

    // للطوارئ: سحب أي USDT الموجود في العقد
    function emergencyWithdrawUSDT(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero addr");
        require(usdt.transfer(to, amount), "transfer fail");
    }
}
