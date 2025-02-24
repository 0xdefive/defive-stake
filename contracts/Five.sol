// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title FIVE Token Contract
/// @notice ERC20 token with a capped supply, minting, burning, and gasless approvals using EIP-2612.
/// @dev Inherits from OpenZeppelin's ERC20, ERC20Permit, and Ownable contracts.
contract FIVE is ERC20, Ownable, ERC20Permit {
    uint256 private _maxSupply;
    uint256 public totalMinted;
    uint256 public totalBurned;

    /// @notice Event emitted when tokens are minted.
    event Mint(address indexed minter, address indexed recipient, uint256 amount);
    /// @notice Event emitted when tokens are burned.
    event Burn(address indexed burner, uint256 amount);
    /// @notice Event emitted when the max supply is decreased.
    event MaxSupplyDecreased(uint256 oldMaxSupply, uint256 newMaxSupply);

    /// @dev Constructor to initialize the token with its name, symbol, and treasury address.
    /// @param initialOwner The address of the treasury to receive the initial minted tokens.
    constructor(
        address initialOwner,
        uint256 migratedAmount
    ) ERC20("DeFive", "FIVE") Ownable(initialOwner) ERC20Permit("DeFive") {
        _maxSupply = 2000000000e18; // Set initial max supply

        require(initialOwner != address(0), "Initial Owner address cannot be zero");
        require(migratedAmount <= _maxSupply, "Initial mint exceeds max supply");
        _mint(initialOwner, migratedAmount);
        totalMinted = migratedAmount;

        emit Mint(msg.sender, initialOwner, migratedAmount);
    }

    /// @notice Mint new tokens, restricted to the MasterFarmer.
    /// @param recipient The address to receive the minted tokens.
    /// @param amount The amount of tokens to mint.
    function mint(address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "Mint to zero address");
        require(totalSupply() + amount <= _maxSupply, "ERC20: minting exceeds max supply");
        _mint(recipient, amount);
        totalMinted += amount;

        emit Mint(msg.sender, recipient, amount);
    }

    /// @notice Burn tokens from the caller's balance.
    /// @param amount The amount of tokens to burn.
    function burn(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance to burn");
        _burn(msg.sender, amount);
        totalBurned += amount;

        emit Burn(msg.sender, amount);
    }

    /// @notice Reduce the maximum token supply. Only decreases are allowed.
    /// @param newMaxSupply The new maximum supply, which must be less than the current max supply.
    function decreaseMaxSupply(uint256 newMaxSupply) external onlyOwner {
        require(newMaxSupply < _maxSupply, "New max supply must be less than the current max supply");
        require(newMaxSupply >= totalSupply(), "New max supply must not be less than the total supply");

        uint256 oldMaxSupply = _maxSupply;
        _maxSupply = newMaxSupply;

        emit MaxSupplyDecreased(oldMaxSupply, newMaxSupply);
    }

    /// @notice Get the current maximum token supply.
    /// @return The current maximum supply of the token.
    function maxSupply() external view returns (uint256) {
        return _maxSupply;
    }
}
