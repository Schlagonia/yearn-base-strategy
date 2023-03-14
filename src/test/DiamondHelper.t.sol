// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import {Setup, IMockStrategy, BaseLibrary, MockStrategy, MockIlliquidStrategy, ERC20Mock, DiamondHelper} from "./utils/Setup.sol";

import {IDiamond} from "../interfaces/IDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";

contract DiamondHelperTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    // Make sure two arrays are identical
    function checkSelectors(
        bytes4[] memory selectors,
        bytes4[] memory _selectors
    ) public {
        assertEq(selectors.length, _selectors.length);

        for (uint256 i; i < _selectors.length; ++i) {
            assertEq(selectors[i], _selectors[i]);
        }
    }

    function isASelector(bytes4 _selector) public returns (bool) {
        bytes4[] memory _selectors = getSelectors();

        for (uint256 i; i < _selectors.length; ++i) {
            if (_selectors[i] == _selector) {
                return true;
            }
        }
    }

    // Check each one through the helper the base library and through the strategy
    function test_helperSetup() public {
        bytes4[] memory _selectors = getSelectors();

        // Check selector array
        bytes4[] memory selectors = diamondHelper.functionSelectors();
        checkSelectors(selectors, _selectors);

        //Check base library
        assertEq(diamondHelper.baseLibrary(), address(BaseLibrary));

        // Check facets functions
        IDiamondLoupe.Facet[] memory facets_ = diamondHelper.facets();
        assertEq(facets_.length, 1);
        assertEq(facets_[0].facetAddress, address(BaseLibrary));
        checkSelectors(facets_[0].functionSelectors, _selectors);
        facets_ = BaseLibrary.facets();
        assertEq(facets_.length, 1);
        assertEq(facets_[0].facetAddress, address(BaseLibrary));
        checkSelectors(facets_[0].functionSelectors, _selectors);
        facets_ = strategy.facets();
        assertEq(facets_.length, 1);
        assertEq(facets_[0].facetAddress, address(BaseLibrary));
        checkSelectors(facets_[0].functionSelectors, _selectors);

        // Check the Facet Addresses is only the library
        address[] memory facetAddresses_ = diamondHelper.facetAddresses();
        assertEq(facetAddresses_.length, 1);
        assertEq(facetAddresses_[0], address(BaseLibrary));
        facetAddresses_ = BaseLibrary.facetAddresses();
        assertEq(facetAddresses_.length, 1);
        assertEq(facetAddresses_[0], address(BaseLibrary));
        facetAddresses_ = strategy.facetAddresses();
        assertEq(facetAddresses_.length, 1);
        assertEq(facetAddresses_[0], address(BaseLibrary));

        // Check facet function selectors for valid facet
        bytes4[] memory facetFunctionSelectors_ = diamondHelper
            .facetFunctionSelectors(address(BaseLibrary));
        checkSelectors(facetFunctionSelectors_, getSelectors());
        facetFunctionSelectors_ = BaseLibrary.facetFunctionSelectors(
            address(BaseLibrary)
        );
        checkSelectors(facetFunctionSelectors_, getSelectors());
        facetFunctionSelectors_ = strategy.facetFunctionSelectors(
            address(BaseLibrary)
        );
        checkSelectors(facetFunctionSelectors_, getSelectors());

        // Check the facet address for valid selectors
        address facetAddress_ = diamondHelper.facetAddress(_selectors[0]);
        assertEq(facetAddress_, address(BaseLibrary));
        facetAddress_ = BaseLibrary.facetAddress(_selectors[1]);
        assertEq(facetAddress_, address(BaseLibrary));
        facetAddress_ = strategy.facetAddress(_selectors[2]);
        assertEq(facetAddress_, address(BaseLibrary));
    }

    // Whether we use the library or the helper we can use the helper interface
    function checkHelperSetup(
        address _toCall,
        address _address,
        bytes4 _selector
    ) public {
        DiamondHelper Helper = DiamondHelper(_toCall);
        bytes4[] memory facetFunctionSelectors_ = Helper.facetFunctionSelectors(
            _address
        );
        address facetAddress_ = Helper.facetAddress(_selector);

        if (_address == address(BaseLibrary)) {
            checkSelectors(facetFunctionSelectors_, getSelectors());
        } else {
            assertEq(facetFunctionSelectors_.length, 0);
        }

        if (isASelector(_selector)) {
            assertEq(facetAddress_, address(BaseLibrary));
        } else {
            assertEq(facetAddress_, address(0));
        }
    }

    // Check both through the library the strategy and directly to the helper get the same answer.
    function test_fuzzHelperSetup(address _address, bytes4 _selector) public {
        checkHelperSetup(address(strategy), _address, _selector);
        checkHelperSetup(address(BaseLibrary), _address, _selector);
        checkHelperSetup(address(diamondHelper), _address, _selector);
    }

    function test_initEmitsDiamondEvent() public {
        ERC20Mock mockToken = new ERC20Mock(
            "Test asset",
            "tTKN",
            address(this),
            0
        );

        // Get what should be emitted in the event
        IDiamond.FacetCut[] memory diamondCuts = new IDiamond.FacetCut[](1);
        diamondCuts[0] = IDiamond.FacetCut(
            address(BaseLibrary),
            IDiamond.FacetCutAction.Add,
            getSelectors()
        );

        // Check the event matches the expected values
        vm.expectEmit(true, true, true, true);
        emit BaseLibrary.DiamondCut(diamondCuts, address(0), new bytes(0));
        new MockStrategy(address(mockToken), address(yieldSource));

        // Check the event matches the expected values
        vm.expectEmit(true, true, true, true);
        emit BaseLibrary.DiamondCut(diamondCuts, address(0), new bytes(0));
        new MockIlliquidStrategy(address(mockToken), address(yieldSource));
    }

    function test_setLibraryTwice_reverts() public {
        // Assure setUp already created the helper correctly
        assertEq(diamondHelper.baseLibrary(), address(BaseLibrary));

        vm.expectRevert("already set");
        diamondHelper.setLibrary(address(100));

        // Make sure nothing changes
        assertEq(diamondHelper.baseLibrary(), address(BaseLibrary));
    }
}
