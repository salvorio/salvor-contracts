//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SalvorMini is ERC721, ERC2981, ERC721Enumerable, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Counters for Counters.Counter;
    using Strings for uint256;

    mapping(uint256 => uint256) public rarityLevels;

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

    EnumerableSet.AddressSet private adminPlatforms;


    /**
    * @notice The mapping contains specific urls including nft meta data. Urls are set only by the collection owner.
    * e.g _tokenURIs[token_id] = “https://ipfs.io/ipfs/xyz”;
    */
    mapping(uint256 => string) private _tokenURIs;
    Counters.Counter private _tokenIds;

    event DefaultRoyaltySet(address receiver, uint96 feeNumerator);
    event RoyaltySet(uint256 tokenId, address receiver, uint96 feeNumerator);
    event PlatformAdded(address indexed platform);
    event PlatformRemoved(address indexed platform);

    constructor(address _receiver) ERC721("Mini Salvors", "MINISALVORS") {
        _setDefaultRoyalty(_receiver, 1500);
    }

    function addAdminPlatform(address _platform) external onlyOwner {
        require(!adminPlatforms.contains(_platform), "already added");
        adminPlatforms.add(_platform);
        emit PlatformAdded(_platform);
    }

    function removeAdminPlatform(address _platform) external onlyOwner {
        require(adminPlatforms.contains(_platform), "not added");
        adminPlatforms.remove(_platform);
        emit PlatformRemoved(_platform);
    }

    function mint(address _receiver, uint256 _rarityLevel) external returns (uint256) {
        require(adminPlatforms.contains(msg.sender), "Only the admin contract can operate");
        _tokenIds.increment();
        uint256 tokenId = _tokenIds.current();
        rarityLevels[tokenId] = _rarityLevel;
        _mint(_receiver, tokenId);
        return tokenId;
    }

    function burn(uint256 _tokenId) external {
        require(adminPlatforms.contains(msg.sender), "Only the admin contract can operate");
        _burn(_tokenId);
    }

    function getRarityLevel(uint256 _tokenId) external view returns (uint256) {
        return rarityLevels[_tokenId];
    }

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
    * @dev Sets default royalty information for the contract.
     * @param _receiver address of the royalty receiver
     * @param _feeNumerator numerator of the royalty fee
     */
    function setDefaultRoyalty(address _receiver, uint96 _feeNumerator) external onlyOwner {
        _setDefaultRoyalty(_receiver, _feeNumerator);
        emit DefaultRoyaltySet(_receiver, _feeNumerator);
    }

    /**
	* @dev Sets the royalty information for a specific token.
    * @param _tokenId ID of the token to set royalty information for.
    * @param _receiver Address that should receive the royalty payments.
    * @param _feeNumerator Numerator of the royalty fee. Must be between 0 and 10,000.
    */
    function setRoyaltyInfo(uint256 _tokenId, address _receiver, uint96 _feeNumerator) external onlyOwner {
        require(_exists(_tokenId), "Token does not exist");
        require(_feeNumerator <= 10000, "Fee numerator must be between 0 and 10,000");

        _setTokenRoyalty(_tokenId, _receiver, _feeNumerator);

        emit RoyaltySet(_tokenId, _receiver, _feeNumerator);
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


    function _baseURI() internal view virtual override returns (string memory) {
        return baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(ERC721, ERC721Enumerable, ERC2981)
    returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
    internal
    override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }
}
