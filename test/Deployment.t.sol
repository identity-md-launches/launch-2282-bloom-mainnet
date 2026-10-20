// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployBloom} from "../script/Deploy.s.sol";
import {Treasury} from "../src/Treasury.sol";
import {FarmFactory} from "../src/FarmFactory.sol";
import {BloomFarm} from "../src/BloomFarm.sol";

contract DeploymentTest is Test {
    function testScriptRehearsalUsesAuthenticatedRequesterAndLeavesTokensUnset() public {
        vm.chainId(1);
        DeployBloom script = new DeployBloom();
        (Treasury treasury, FarmFactory factory) = script.deploy(script.REQUESTER());
        assertEq(treasury.owner(), script.REQUESTER());
        assertEq(factory.owner(), script.REQUESTER());
        assertEq(factory.treasury(), address(treasury));
        assertEq(factory.bloom(), address(0));
        assertEq(factory.simd(), address(0));
        assertEq(factory.weth(), address(0));
        assertEq(factory.farmCount(), 0);
        _checkRuntime(address(treasury).code);
        _checkRuntime(address(factory).code);
    }

    function testScriptRejectsWrongChainAndWorkerOwnership() public {
        DeployBloom script = new DeployBloom();
        address requester = script.REQUESTER();
        vm.chainId(2);
        vm.expectRevert(DeployBloom.WrongChain.selector);
        script.deploy(requester);
        vm.chainId(1);
        vm.expectRevert(DeployBloom.WrongOwner.selector);
        script.deploy(address(this));
    }

    function testConstructorsDoNotCallDependenciesOnEmptyChain() public {
        address requester = makeAddr("requester");
        address futureTreasury = makeAddr("future treasury");
        address futureSIMD = makeAddr("future sIMD");
        address futureBloom = makeAddr("future BLOOM");
        assertEq(futureTreasury.code.length, 0);
        FarmFactory factory = new FarmFactory(requester, futureTreasury);
        BloomFarm farm =
            new BloomFarm(requester, futureTreasury, futureSIMD, futureBloom, 18, BloomFarm.Kind.SIMD);
        assertEq(factory.owner(), requester);
        assertEq(farm.owner(), requester);
        assertTrue(farm.depositsPaused());
        _checkRuntime(address(farm).code);
    }

    function testInitCodeAndRuntimeFitMainnetLimits() public pure {
        assertLe(type(Treasury).creationCode.length + 32, 49_152);
        assertLe(type(FarmFactory).creationCode.length + 64, 49_152);
        assertLe(type(BloomFarm).creationCode.length + 192, 49_152);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
