//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

interface IVeART {
    function depositART(uint256 _amount) external;
    function burnSalvorMiniToBoostVeART(uint256 _tokenId) external;
}

// it is used only for unit tests.
contract ERC721Dummy is ERC721, ERC2981 {
    bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;
    address public veART;
    constructor(string memory tokenName, string memory symbol) ERC721(tokenName, symbol) {}

    function mint(
        uint256 _tokenId,
        address royaltyRecipient,
        uint96 royaltyValue
    )
        external
    {
        super._mint(msg.sender, _tokenId);
        if (royaltyValue > 0) {
            _setTokenRoyalty(_tokenId, royaltyRecipient, royaltyValue);
        }
    }

    function setVeART(address _veART) external {
        veART = _veART;
    }

    function depositART(uint256 _amount) external {
        IVeART(veART).depositART(_amount);
    }

    function burnSalvorMiniToBoostVeART(uint256 _tokenId) external {
        IVeART(veART).burnSalvorMiniToBoostVeART(_tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC2981) returns (bool) {
    if (interfaceId == _INTERFACE_ID_EIP2981) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }
}
