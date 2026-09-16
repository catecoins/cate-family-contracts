// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CateFamilyToken
/// @notice The fixed-supply BEP20 minted by CateFamilyFactory at launch.
///
/// Deliberately the most boring ERC20 possible:
///   - the entire supply is minted once, in the constructor, to the factory;
///   - there is no owner, no minter, no pauser, no blocklist;
///   - there are no transfer hooks and no transfer tax.
///
/// That last property is load-bearing. A hook-free token is tradeable by every
/// router and aggregator that routes PancakeSwap V3 liquidity, and it lets the
/// locker burn the token side of collected fees without the transfer ever being
/// able to revert. Holder rewards are therefore paid as buyback-and-burn rather
/// than per-wallet dividends — see CateFamilyHolderDistributor.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyToken is ERC20 {
    /// @notice Wallet that launched this token. Informational only: it carries
    /// no privileges whatsoever over the token.
    address public immutable creator;

    /// @notice Off-chain or on-chain metadata pointer set at launch and frozen
    /// forever after. CateFamily writes `onchain://<chainId>/<address>` URIs
    /// pointing at a CateFamilyImageStore blob.
    string public metadataURI;

    /// @notice Marketing constant, mirrored from the launch surface.
    string public constant CAPPUCCINO = "launch on cappuccino.family";

    error EmptySupply();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address mintTo_,
        string memory metadataURI_,
        address creator_
    ) ERC20(name_, symbol_) {
        if (totalSupply_ == 0) revert EmptySupply();
        creator = creator_;
        metadataURI = metadataURI_;
        _mint(mintTo_, totalSupply_);
    }
}
