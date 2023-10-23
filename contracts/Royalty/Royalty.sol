//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./LibRoyalty.sol";
import "./IRoyalty.sol";

/**
* @title Royalty
* @notice OpenZeppelins' ERC165 extended with new features with multi royalties
*/
contract Royalty is IRoyalty, ERC165 {

    // list of the royalties that contains percentages for each account
    LibRoyalty.Royalty[] public defaultRoyalties;
    // list of the royalties for the each nft tokenId that contains percentages for each account
    mapping (uint256 => LibRoyalty.Royalty[]) public royalties;
    // default royalty receiver
    address public defaultRoyaltyReceiver;
    // allowed max royalty percentage value
    uint96 public maxPercentage;

    constructor(LibRoyalty.Royalty[] memory _defaultRoyalties, uint96 _maxPercentage) {
        defaultRoyaltyReceiver = msg.sender;
        maxPercentage = _maxPercentage;
        _setDefaultRoyalties(_defaultRoyalties);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IRoyalty).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
    * @notice returns default royalty list
    */
    function getDefaultRoyalties() external view virtual override returns (LibRoyalty.Royalty[] memory) {
        return defaultRoyalties;
    }

    /**
    * @notice returns royalty list for the tokenId
    * @param _tokenId nft tokenId
    */
    function getTokenRoyalties(uint256 _tokenId) external view virtual override returns (LibRoyalty.Royalty[] memory) {
        return royalties[_tokenId];
    }

    /**
    * @notice Multi royalties are not common for every marketplace.
    * So if an nft minter decides to list their own nft on another marketplace then a single royalty model should be worked.
    * The function aggregates the values on multi royalties and calculates royalty amount using the total value.
    * receiver is default contract owner
    * @param _tokenId nft tokenId
    * @param _salePrice amount in ethers
    */
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view virtual override returns (address receiver, uint256 royaltyAmount) {
        LibRoyalty.Royalty[] memory existingRoyalties = royalties[_tokenId].length > 0 ? royalties[_tokenId] : defaultRoyalties;
        uint96 totalValue;
        for (uint i = 0; i < existingRoyalties.length; i++) {
            totalValue += existingRoyalties[i].value;
        }
        return (totalValue > 0 ? defaultRoyaltyReceiver : address(0), (_salePrice * totalValue) / 10000);
    }

    /**
    * @notice returns calculated receiver and amounts for defined multi royalty receivers.
    * @param _tokenId nft tokenId
    * @param _salePrice amount in ethers
    */
    function multiRoyaltyInfo(uint256 _tokenId, uint256 _salePrice) external view virtual override returns (LibRoyalty.Part[] memory) {
        LibRoyalty.Royalty[] memory existingRoyalties = royalties[_tokenId].length > 0 ? royalties[_tokenId] : defaultRoyalties;
        LibRoyalty.Part[] memory calculatedParts = new LibRoyalty.Part[](existingRoyalties.length);
        for (uint i = 0; i < existingRoyalties.length; i++) {
            LibRoyalty.Part memory calculatedPart;
            calculatedPart.account = existingRoyalties[i].account;
            calculatedPart.value = (_salePrice * existingRoyalties[i].value) / 10000;
            calculatedParts[i] = calculatedPart;
        }
        return calculatedParts;
    }

    /**
    * @notice updates the default royalty receiver.
    * defaultRoyaltyReceiver specifies the royalty receiver for the platforms that supports only single royalty receiver.
    * @param _defaultRoyaltyReceiver royalty receiver address
    */
    function setDefaultRoyaltyReceiver(address _defaultRoyaltyReceiver) external virtual override {
        _setDefaultRoyaltyReceiver(_defaultRoyaltyReceiver);
    }

    /**
    * @notice updates the default royalties that includes multi royalty information.
    * default royalties is applied to all nft’s that don’t include any royalty specifically.
    * @param _defaultRoyalties list of the royalties that contains percentages for each account
    */
    function setDefaultRoyalties(LibRoyalty.Royalty[] memory _defaultRoyalties) external virtual override {
        _setDefaultRoyalties(_defaultRoyalties);
    }

    /**
    * @notice updates the royalties for a specific nft.
    * @param _tokenId nft tokenId
    * @param _royalties list of the royalties that contains percentages for each account
    */
    function saveRoyalties(uint256 _tokenId, LibRoyalty.Royalty[] memory _royalties) external virtual override {
        _saveRoyalties(_tokenId, _royalties);
    }

    function _setDefaultRoyaltyReceiver(address _defaultRoyaltyReceiver) internal virtual {
        // if given address is 0x0 then it means reset the royalties
        if (_defaultRoyaltyReceiver == address(0)) {
            delete defaultRoyalties;
        }
        defaultRoyaltyReceiver = _defaultRoyaltyReceiver;
    }

    function _setDefaultRoyalties(LibRoyalty.Royalty[] memory _defaultRoyalties) internal virtual {
        emit DefaultRoyaltiesSet(_defaultRoyalties, defaultRoyalties);
        delete defaultRoyalties;
        uint96 totalValue;
        for (uint i = 0; i < _defaultRoyalties.length; i++) {
            if (_defaultRoyalties[i].account != address(0) && _defaultRoyalties[i].value != 0) {
                totalValue += _defaultRoyalties[i].value;
                LibRoyalty.Royalty memory defaultRoyalty;
                defaultRoyalty.account = _defaultRoyalties[i].account;
                defaultRoyalty.value = _defaultRoyalties[i].value;
                defaultRoyalties.push(defaultRoyalty);
            }
        }
        require(totalValue <= maxPercentage, "Royalty total value should be <= maxPercentage");
    }

    function _saveRoyalties(uint256 _tokenId, LibRoyalty.Royalty[] memory _royalties) internal virtual {
        emit RoyaltiesSet(_tokenId, _royalties, royalties[_tokenId]);
        uint96 totalValue;
        delete royalties[_tokenId];
        for (uint i = 0; i < _royalties.length; i++) {
            if (_royalties[i].account != address(0) && _royalties[i].value != 0) {
                totalValue += _royalties[i].value;
                LibRoyalty.Royalty memory royalty;
                royalty.account = _royalties[i].account;
                royalty.value = _royalties[i].value;

                royalties[_tokenId].push(royalty);
            }
        }

        require(totalValue <= maxPercentage, "Royalty total value should be <= maxPercentage");
    }
}
