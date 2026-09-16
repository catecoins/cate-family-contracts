// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CateFamilyImageStore
/// @notice Publishes token artwork as immutable contract bytecode (SSTORE2).
///
/// Launch metadata must outlive any server we run, so artwork is written into
/// the runtime code of a throwaway "pointer" contract and referenced from the
/// token's `metadataURI` as `onchain://<chainId>/<pointer>`. Bytecode is the
/// cheapest durable blob storage the EVM offers — roughly 200 gas per byte via
/// CODECOPY at deploy time versus 20,000 gas per 32-byte SSTORE word.
///
/// The pointer's runtime begins with a STOP opcode, so it can never be called
/// or self-destructed; the bytes after it are the raw image. Readers pull them
/// back with EXTCODECOPY, skipping that first byte.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyImageStore {
    /// @dev EIP-170 caps deployed runtime code at 24,576 bytes; one byte of
    /// that budget is the STOP prefix.
    uint256 public constant MAX_IMAGE_BYTES = 24_575;

    /// @notice Content type recorded for a pointer, e.g. "image/png".
    mapping(address pointer => string contentType) public contentTypeOf;

    event ImagePublished(address indexed pointer, address indexed publisher, uint256 size, string contentType);

    error EmptyImage();
    error ImageTooLarge(uint256 size, uint256 maxSize);
    error ContentTypeTooLong();
    error DeploymentFailed();

    /// @notice Writes `data` to a fresh pointer contract and returns its address.
    /// @param data Raw image bytes (PNG, JPEG, GIF or WebP).
    /// @param contentType MIME type recorded alongside the pointer.
    function publish(bytes calldata data, string calldata contentType) external returns (address pointer) {
        uint256 size = data.length;
        if (size == 0) revert EmptyImage();
        if (size > MAX_IMAGE_BYTES) revert ImageTooLarge(size, MAX_IMAGE_BYTES);
        if (bytes(contentType).length > 64) revert ContentTypeTooLong();

        // Init code that CODECOPYs the payload into place and returns it:
        //   63 <len:4>  PUSH4 runtimeLength
        //   80          DUP1
        //   60 0E       PUSH1 14           (offset of the payload in init code)
        //   60 00       PUSH1 0
        //   39          CODECOPY
        //   60 00       PUSH1 0
        //   F3          RETURN
        //   00          STOP               (first byte of the runtime)
        bytes memory initCode = abi.encodePacked(
            hex"63", uint32(size + 1), hex"80_60_0E_60_00_39_60_00_F3_00", data
        );

        assembly ("memory-safe") {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert DeploymentFailed();

        contentTypeOf[pointer] = contentType;
        emit ImagePublished(pointer, msg.sender, size, contentType);
    }

    /// @notice Reads the image bytes previously written to `pointer`.
    function read(address pointer) external view returns (bytes memory data) {
        uint256 codeSize = pointer.code.length;
        if (codeSize <= 1) return "";
        uint256 size = codeSize - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }

    /// @notice Byte length of the image held at `pointer`.
    function sizeOf(address pointer) external view returns (uint256) {
        uint256 codeSize = pointer.code.length;
        return codeSize <= 1 ? 0 : codeSize - 1;
    }
}
