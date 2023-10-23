//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./LibStructSalvor.sol";

contract SalvorNFTCollection is ERC721, ERC721Enumerable, Ownable, Pausable, ReentrancyGuard {

    using SafeMath for uint256;
    using Counters for Counters.Counter;
    using Strings for uint256;

    uint256 public immutable MAX_SUPPLY = 8888;
    uint256 public immutable LEGENDARY_ID_START = 8877;
    uint256 public salvorsLength;
    uint256 public salvorMaxAttributeValue;

    mapping (uint256 => LibStructSalvor.Salvor) public salvors;

    mapping (uint256 => address) public salvorIndexToOwner;

    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;
    string public baseExtension = ".json";
    string public baseTokenURI;

    Counters.Counter private _tokenIds;

    constructor(string memory tokenName, string memory symbol) ERC721(tokenName, symbol) {
        salvorMaxAttributeValue = 10;
    }

    function getChainID() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseTokenURI;
    }

    function setBaseURI(string memory _baseTokenURI) public onlyOwner {
        baseTokenURI = _baseTokenURI;
    }

    function setBaseExtension(string memory _newBaseExtension) public onlyOwner {
        baseExtension = _newBaseExtension;
    }

    //input a NFT token ID and get the IPFS URI
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        string memory currentBaseURI = _baseURI();
        return bytes(currentBaseURI).length > 0
        ? string(abi.encodePacked(currentBaseURI, tokenId.toString(), baseExtension))
        : "";
    }

    function enoughRandom() internal view returns (uint256) {
        return
        uint256(
            keccak256(
                abi.encodePacked(
                // solhint-disable-next-line
                    block.timestamp,
                    msg.sender,
                    blockhash(block.number)
                )
            )
        );
    }

    function _mintSalvors(uint256 numberOfMints) external onlyOwner {
        uint256 totalSalvors = salvorsLength.add(numberOfMints);
        require(MAX_SUPPLY >= totalSalvors, "max salvor count is exceeded");
        uint256 seed = enoughRandom();

        for (uint256 i; i < numberOfMints; i++) {
            seed >>= i;
            _tokenIds.increment();
            uint256 tokenId = _tokenIds.current();

            _mint(msg.sender, tokenId);

            if (tokenId >= LEGENDARY_ID_START) {
                salvors[tokenId] = generate(seed, 5, 6);
            } else {
                salvors[tokenId] = generate(seed, 1, 10);
            }
        }
    }

    function generate(uint256 seed, uint256 minAttributeValue, uint256 randCap) internal view returns (LibStructSalvor.Salvor memory) {
        return
        LibStructSalvor.Salvor({
        strength: uint8(
                ((seed >> (8 * 1)) % randCap) + minAttributeValue
            ),
        agility: uint8(
                ((seed >> (8 * 2)) % randCap) + minAttributeValue
            ),
        vitality: uint8(
                ((seed >> (8 * 3)) % randCap) + minAttributeValue
            ),
        intelligence: uint8(
                ((seed >> (8 * 4)) % randCap) + minAttributeValue
            ),
        fertility: uint8(
                ((seed >> (8 * 5)) % randCap) + minAttributeValue
            ),
        level: 1,
        rebirths: 0,
        birthTime: uint64(block.timestamp)
        });

    }

    function getSalvor(uint256 tokenId) external view returns (LibStructSalvor.Salvor memory) {
        return salvors[tokenId];
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function balance() external view returns (uint) {
        return address(this).balance;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
        if(interfaceId == _INTERFACE_ID_ERC2981) {
            return true;
        }

        return super.supportsInterface(interfaceId);
    }
}