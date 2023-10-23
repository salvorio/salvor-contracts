//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract TheSalvorsCollection is ERC721, ERC721Enumerable, ERC2981, ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    using Strings for uint256;

    struct UserInfo {
        uint256 mintAmount;
        uint256 allowedAmount;
    }

    struct Whitelist {
        uint256 price;
        uint256 maxCap;
        uint256 mintAmount;
        uint256 totalAllowedAmount;
        bool isActivated;
    }


    mapping(uint8 => Whitelist) public wls;
    mapping(uint8 => Whitelist) public ps;
    mapping(uint8 => mapping(address => UserInfo)) public users;

    uint256 public maxCap;
    string public baseExtension;
    string public baseTokenURI;

    mapping(uint256 => string) private _tokenURIs;
    Counters.Counter private _tokenIds;

    event DefaultRoyaltySet(address indexed receiver, uint96 feeNumerator);
    event RoyaltySet(uint256 indexed tokenId, address indexed receiver, uint96 feeNumerator);
    event MintSale(uint256 amount, address indexed receiver, uint256 price, string indexed mintType);

    constructor(address _receiver) ERC721("The Salvors", "SALVOR") {
        maxCap = 10050;
        _setDefaultRoyalty(_receiver, 1500);
    }

    receive() external payable {}

    modifier isEOA() {
        require(tx.origin == msg.sender, "Unauthorized");
        _;
    }

    function withdrawBalance(address payable _receiver) external onlyOwner {
        _receiver.transfer(this.balance());
    }

    function setDefaultRoyalty(address _receiver, uint96 _feeNumerator) external onlyOwner {
        _setDefaultRoyalty(_receiver, _feeNumerator);
        emit DefaultRoyaltySet(_receiver, _feeNumerator);
    }

    function setRoyaltyInfo(uint256 _tokenId, address _receiver, uint96 _feeNumerator) external onlyOwner {
        require(_exists(_tokenId), "Token does not exist");
        require(_feeNumerator <= 10000, "Fee numerator must be between 0 and 10,000");

        _setTokenRoyalty(_tokenId, _receiver, _feeNumerator);

        emit RoyaltySet(_tokenId, _receiver, _feeNumerator);
    }

    function togglePublicSale(uint8 _part, bool _isPublicSaleActivated) external onlyOwner {
        ps[_part].isActivated = _isPublicSaleActivated;
    }

    function toggleWlSale(uint8 _part, bool _isWlSaleActivated) external onlyOwner {
        wls[_part].isActivated = _isWlSaleActivated;
    }

    function setPublicSaleInfo(uint8 part, uint256 _maxCap, uint256 _price) external onlyOwner {
        uint256 totalMaxCap;
        for (uint8 i = 0; i < 2; i++) {
            if (part != i) {
                totalMaxCap += ps[i].maxCap;
            }
        }
        for (uint8 i = 0; i < 2; i++) {
            totalMaxCap += wls[i].maxCap;
        }
        require((totalMaxCap +_maxCap) <= maxCap, "Total maximum capacity exceeded");
        ps[part].maxCap = _maxCap;
        ps[part].price = _price;
    }

    function setWhitelistInfo(uint8 part, uint256 _maxCap, uint256 _price) external onlyOwner {
        uint256 totalMaxCap;
        for (uint8 i = 0; i < 2; i++) {
            totalMaxCap += ps[i].maxCap;
        }
        for (uint8 i = 0; i < 2; i++) {
            if (part != i) {
                totalMaxCap += wls[i].maxCap;
            }
        }
        require((totalMaxCap +_maxCap) <= maxCap, "Total maximum capacity exceeded");
        wls[part].maxCap = _maxCap;
        wls[part].price = _price;
    }

    function setWhitelistUsers(uint8 _part, address[] calldata _users, uint256[] calldata _allowedAmounts) external onlyOwner {
        require(_part < 2, "part must be less than maximumPartCount");

        uint256 len = _users.length;
        for (uint256 i = 0; i < len; i++) {
            require(_allowedAmounts[i] <= wls[_part].maxCap, "exceeded maxCap limit");
            if (users[_part][_users[i]].allowedAmount > 0) {
                wls[_part].totalAllowedAmount -= users[_part][_users[i]].allowedAmount;
            }
            users[_part][_users[i]].allowedAmount = _allowedAmounts[i];
            wls[_part].totalAllowedAmount += _allowedAmounts[i];
        }
    }

    function wlMint(uint8 _part, uint256 _amount) external payable isEOA nonReentrant {
        require(wls[_part].isActivated, "Whitelist sale has not been started yet");
        require(_amount <= 20, "Exceeded maximum buy limit of 20 tokens per transaction");

        require((totalSupply() + _amount) <= maxCap, "Maximum token supply has been reached");
        require((wls[_part].mintAmount + _amount) <= wls[_part].maxCap, "Maximum cap has been reached for this whitelist");
        string memory mintType = 'wl1';
        if (_part == 0) {
            mintType = 'wl0';
            require((users[_part][msg.sender].mintAmount + _amount) <= users[_part][msg.sender].allowedAmount, "Allowed amount has been reached for this user");
        } else {
            uint256 allowedAmount = users[_part][msg.sender].allowedAmount + users[_part - 1][msg.sender].allowedAmount;
            uint256 userMintAmount = users[_part][msg.sender].mintAmount + users[_part - 1][msg.sender].mintAmount;
            require((userMintAmount + _amount) <= allowedAmount, "Allowed amount has been reached for this user");
        }

        emit MintSale(_amount, msg.sender, msg.value, mintType);


        require(msg.value >= _amount * wls[_part].price, "Insufficient payment");

        users[_part][msg.sender].mintAmount += _amount;
        wls[_part].mintAmount += _amount;
        for (uint256 i = 0; i < _amount; i++) {
            _tokenIds.increment();
            _mint(msg.sender, _tokenIds.current());
        }
    }

    function publicMint(uint8 _part, uint256 _amount) external isEOA payable {
        require(ps[_part].isActivated, "Public sale has not been started yet");
        require(_amount <= 100, "Exceeded maximum buy limit of 100 tokens per transaction");
        require((totalSupply() + _amount) <= maxCap, "Maximum token supply reached");
        require((ps[_part].mintAmount + _amount) <= ps[_part].maxCap, "Maximum cap has been reached for this public sale part");
        require(msg.value >= (_amount * ps[_part].price), "Insufficient payment amount");

        ps[_part].mintAmount += _amount;
        for (uint256 i = 0; i < _amount; i++) {
            _tokenIds.increment();
            _mint(msg.sender, _tokenIds.current());
        }
        emit MintSale(_amount, msg.sender, msg.value, "public");
    }

    function adminMint(uint256 _amount) external onlyOwner {
        require((totalSupply() + _amount) <= maxCap, "Maximum token supply reached");
        for (uint256 i = 0; i < _amount; i++) {
            _tokenIds.increment();
            _mint(msg.sender, _tokenIds.current());
        }
    }

    function setBaseTokenURI(string memory _baseTokenURI) external onlyOwner {
        baseTokenURI = _baseTokenURI;
    }

    function setBaseExtension(string memory _baseExtension) external onlyOwner {
        baseExtension = _baseExtension;
    }

    function setTokenURI(uint256 _tokenId, string memory _tokenURI) public onlyOwner {
        require(_exists(_tokenId), "ERC721URIStorage: URI set of nonexistent token");
        _tokenURIs[_tokenId] = _tokenURI;
    }

    function balance() external view returns (uint) {
        return address(this).balance;
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

    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId);
    }
}