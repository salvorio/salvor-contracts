//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "../Royalty/Royalty.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../Royalty/LibRoyalty.sol";

/**
* @title NFTCollectible
* @notice A Template contract that can be deployed from users on Salvor.io. It allows users to mint, transfer NFT’s and define royalties.
*/
contract NFTCollectible is ERC721, ERC721Enumerable, Royalty, Ownable {
    using Counters for Counters.Counter;
    using Strings for uint256;

    bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;
    /**
    * @notice allows collection owners to define an extension as a suffix to the baseURL.
    * e.g baseExtension = “.json”;
    */
    string public baseExtension;

    /**
    * @notice allows collection owners to define an extension as a suffix to the baseURL.
    * e.g baseTokenURI = “https://salvor.io/”;
    */
    string public baseTokenURI;

    /**
    * @notice The mapping contains specific urls including nft meta data. Urls are set only by the collection owner.
    * e.g _tokenURIs[token_id] = “https://ipfs.io/ipfs/xyz”;
    */
    mapping(uint256 => string) private _tokenURIs;
    Counters.Counter private _tokenIds;

    constructor(string memory tokenName, string memory symbol, LibRoyalty.Royalty[] memory _defaultRoyalties)
        ERC721(tokenName, symbol)
        Royalty(_defaultRoyalties, 2500) {}

    /**
    * @notice allows the contract owner to update baseTokenURI.
    * @param _baseTokenURI base url for the tokenUri
    */
    function setBaseTokenURI(string memory _baseTokenURI) external onlyOwner {
        baseTokenURI = _baseTokenURI;
    }

    /**
    * @notice allows the contract owner to update baseExtension.
    * @param _baseExtension extension to add as a suffix
    */
    function setBaseExtension(string memory _baseExtension) external onlyOwner {
        baseExtension = _baseExtension;
    }

    /**
    * @notice allows the contract owner to update the default royalty receiver.
    * defaultRoyaltyReceiver specifies the royalty receiver for the platforms that supports only single royalty receiver.
    * @param _defaultRoyaltyReceiver royalty receiver address
    */
    function setDefaultRoyaltyReceiver(address _defaultRoyaltyReceiver) external override onlyOwner {
        _setDefaultRoyaltyReceiver(_defaultRoyaltyReceiver);
    }

    /**
    * @notice allows the contract owner to update the default royalties that includes multi royalty information.
    * The contract owner can apply default royalties to all nft’s that don’t include any royalty specifically.
    * Total amount of royalty percentages cannot be higher than %25.
    * @param _defaultRoyalties list of the royalties that contains percentages for each account
    */
    function setDefaultRoyalties(LibRoyalty.Royalty[] memory _defaultRoyalties) external override onlyOwner {
        _setDefaultRoyalties(_defaultRoyalties);
    }

    /**
    * @notice allows the contract owner to update the royalties for a specific nft.
    * Total amount of royalty percentages cannot be higher than %25.
    * @param _tokenId nft tokenId
    * @param _royalties list of the royalties that contains percentages for each account
    */
    function saveRoyalties(uint256 _tokenId, LibRoyalty.Royalty[] memory _royalties) external override onlyOwner {
        require(ownerOf(_tokenId) == owner(), "token does not belongs to contract owner");
        _saveRoyalties(_tokenId, _royalties);
    }

    /**
    * @notice allows the contract owner to update the royalties for a specific nft.
    * Total amount of royalty percentages cannot be higher than %25.
    * @param _tokenId nft tokenId
    * @param _tokenURI provides meta data for the nft
    */
    function setTokenURI(uint256 _tokenId, string memory _tokenURI) public onlyOwner {
        require(_exists(_tokenId), "ERC721URIStorage: URI set of nonexistent token");
        _tokenURIs[_tokenId] = _tokenURI;
    }

    /**
    * @notice Allows the nft owner to mint an nft.
    * Specifically tokenUri can be set for each nft via _tokenUri parameter.
    * In the case that the _tokenUri is not set then baseTokenURI and  baseExtension are used to generate a token uri.
    * Specifically royalties can be set for each nft via _royalties parameter.
    * In the case of the _royalties is not set then defaultRoyalties is used to process royalty flow.
    * @param _tokenUri provides meta data for the nft
    * @param _royalties list of the royalties that contains percentages for each account
    */
    function mint(string memory _tokenUri, LibRoyalty.Royalty[] memory _royalties) external onlyOwner returns (uint256) {
        return _mint(_tokenUri, _royalties);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC721Enumerable, Royalty)
        returns (bool)
    {
        if (interfaceId == _INTERFACE_ID_EIP2981) {
            return true;
        }
        return super.supportsInterface(interfaceId);
    }

    function balance() external view returns (uint) {
        return address(this).balance;
    }

    /**
    * @notice allows all platforms to access the uri of nft containing metadata.
    * If the token is not specifically set, it uses the baseTokenURI and baseExtension to show a uri.
    * In this case collection owners can use a specific base uri to show a generic uri.
    * e.g  “https://ipfs.io/ipfs/xyz”; --> customUri for the specific nft
    * e.g “https://salvor.io/1.json”; --> baseURI + tokenId + baseExtension
    * @param _tokenId nft tokenId
    */
    function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
        require(_exists(_tokenId), "ERC721Metadata: URI query for nonexistent token");
        string memory _tokenURI = _tokenURIs[_tokenId];
        if (bytes(_tokenURI).length > 0) {
            return _tokenURI;
        }
        string memory currentBaseURI = _baseURI();
        return bytes(currentBaseURI).length > 0
        ? string(abi.encodePacked(currentBaseURI, _tokenId.toString(), baseExtension))
        : super.tokenURI(_tokenId);
    }

    function _mint(string memory _tokenUri, LibRoyalty.Royalty[] memory _royalties) internal returns (uint256) {
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();
        _mint(owner(), newItemId);
        if (bytes(_tokenUri).length > 0) {
            setTokenURI(newItemId, _tokenUri);
        }
        _saveRoyalties(newItemId, _royalties);
        return newItemId;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseTokenURI;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }
}