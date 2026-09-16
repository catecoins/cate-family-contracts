// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CateFamilyCurveToken
/// @notice The fixed-supply BEP20 minted by CateFamilyCurveLaunchpad for a bonding-curve
/// launch. Identical to CateFamilyToken after graduation; before it, the
/// token can only move to or from the curve.
///
/// That single restriction is what makes the curve's per-wallet caps
/// enforceable and what rules out the liquidity-migration exploits seen on
/// other launchpads: until the curve itself calls `launch()` inside
/// graduation, nobody can place these tokens in a pool, a pair, or anywhere
/// else. There is no owner, no other privilege, and `launch()` is one-way.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyCurveToken is ERC20 {
    /// @notice The launchpad that holds the curve; the only address tokens
    /// may move to or from before graduation, and the only caller of `launch`.
    address public immutable curve;

    /// @notice Wallet that created the token. Informational only.
    address public immutable creator;

    /// @notice Metadata pointer set at creation and frozen.
    string public metadataURI;

    /// @notice False until the curve graduates; true forever after.
    bool public launched;

    event Launched();

    error EmptySupply();
    error OnlyCurve();
    error NotLaunched();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address curve_,
        string memory metadataURI_,
        address creator_
    ) ERC20(name_, symbol_) {
        if (totalSupply_ == 0) revert EmptySupply();
        curve = curve_;
        creator = creator_;
        metadataURI = metadataURI_;
        _mint(curve_, totalSupply_);
    }

    /// @notice Lifts the transfer restriction. Curve only, once.
    function launch() external {
        if (msg.sender != curve) revert OnlyCurve();
        if (!launched) {
            launched = true;
            emit Launched();
        }
    }

    /// @dev Before graduation every transfer must touch the curve. The mint
    /// (from == 0) is the curve's own supply.
    function _update(address from, address to, uint256 value) internal override {
        if (!launched && from != address(0) && from != curve && to != curve) revert NotLaunched();
        super._update(from, to, value);
    }
}
