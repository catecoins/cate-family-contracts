// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CateFamilyImageStore} from "../src/CateFamilyImageStore.sol";

contract ImageStoreTest is Test {
    CateFamilyImageStore internal store;

    function setUp() public {
        store = new CateFamilyImageStore();
    }

    function test_PublishAndReadRoundTrip() public {
        bytes memory png = hex"89504e470d0a1a0a0000000d49484452";
        address pointer = store.publish(png, "image/png");

        assertEq(store.read(pointer), png, "bytes must survive the round trip");
        assertEq(store.sizeOf(pointer), png.length);
        assertEq(store.contentTypeOf(pointer), "image/png");
    }

    /// @dev The pointer's runtime starts with STOP, so it can never be invoked.
    function test_PointerIsInert() public {
        address pointer = store.publish(hex"deadbeef", "image/png");
        (bool ok,) = pointer.call(abi.encodeWithSignature("anything()"));
        assertTrue(ok, "a STOP-prefixed pointer halts instead of executing");
        assertEq(pointer.code.length, 5, "one STOP byte plus four payload bytes");
    }

    function testFuzz_ArbitraryPayloadRoundTrips(bytes calldata data) public {
        vm.assume(data.length > 0 && data.length <= store.MAX_IMAGE_BYTES());
        address pointer = store.publish(data, "image/webp");
        assertEq(store.read(pointer), data);
    }

    function test_RevertsOnEmptyImage() public {
        vm.expectRevert(CateFamilyImageStore.EmptyImage.selector);
        store.publish("", "image/png");
    }

    function test_RevertsAboveContractSizeLimit() public {
        bytes memory tooBig = new bytes(store.MAX_IMAGE_BYTES() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CateFamilyImageStore.ImageTooLarge.selector, tooBig.length, store.MAX_IMAGE_BYTES()
            )
        );
        store.publish(tooBig, "image/png");
    }

    function test_AcceptsExactlyTheMaximumSize() public {
        bytes memory atLimit = new bytes(store.MAX_IMAGE_BYTES());
        address pointer = store.publish(atLimit, "image/png");
        assertEq(store.sizeOf(pointer), store.MAX_IMAGE_BYTES());
    }

    function test_ReadOfUnknownPointerIsEmpty() public {
        assertEq(store.read(makeAddr("nothing")).length, 0);
    }
}
