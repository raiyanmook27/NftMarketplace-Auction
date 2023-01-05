//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 *  @title A NFT Marketplace Auction
 *  @author Raiyan Mukhtar
 */

contract NftMarketPlaceAuction is Ownable, ReentrancyGuard, IERC721Receiver {
    struct AuctionItem {
        uint256 index;
        address nft;
        uint nftID;
        address creator;
        address currentBidOwner;
        uint256 currentBidPrice;
        uint256 endAuction;
        uint256 bidCount;
    }

    AuctionItem[] public allAuctions;

    mapping(uint => mapping(address => uint256)) public fundsByBidder;

    uint256 index;

    event AuctionCreated(
        uint indexed _auctionId,
        address indexed nft,
        uint256 _nftId
    );
    event BidPlaced(uint256 indexed _auctionId, address indexed creator);
    event AuctionCanceled(uint256 indexed _auctionId);
    event NftClaimed(uint256 indexed _auction, uint256 indexed _nftId);
    event CreatorFundsClaimed(
        uint256 indexed _auctionId,
        uint256 indexed _amount
    );
    event FundsWithdrawn(
        uint256 indexed _auctionId,
        address indexed _receiver,
        uint256 indexed _amount
    );

    event NftRefunded(uint256 indexed _auctionId, address indexed receiver);

    modifier onlyCreator(uint _auctionID) {
        //check if caller is creator
        AuctionItem memory auctionItem = allAuctions[_auctionID];
        require(msg.sender == auctionItem.creator, "Not owner");
        _;
    }

    constructor() {}

    /**
     * @notice Creates an auction for an nft.
     * @param _nft //Nft Contract address
     * @param _nftID // nft id
     * @param _initialBid //minimum bid amount
     * @param _endAuction //maximum time the auction can run.
     */
    function createAuction(
        address _nft,
        uint _nftID,
        uint _initialBid,
        uint256 _endAuction
    ) external returns (uint256) {
        require(_nft != address(0));
        require(_endAuction >= block.timestamp, "Invalid Date");

        require(_initialBid != 0, "invalid bid price");

        require(IERC721(_nft).ownerOf(_nftID) == msg.sender, "Not owner");

        require(
            IERC721(_nft).getApproved(_nftID) == address(this),
            "not approved"
        );

        AuctionItem memory newAuction = AuctionItem({
            index: index,
            nft: _nft,
            nftID: _nftID,
            creator: msg.sender,
            currentBidOwner: address(0x0),
            currentBidPrice: _initialBid,
            endAuction: _endAuction,
            bidCount: 0
        });

        allAuctions.push(newAuction);
        index++;

        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _nftID);

        emit AuctionCreated(index, newAuction.nft, newAuction.nftID);

        return index;
    }

    /**
     * @notice Place a bid to a specific auctionID
     * @param _auctionId //Id of the auction to bid.
     */
    function placeBid(uint256 _auctionId) external payable returns (bool) {
        require(isOpen(_auctionId), "Auction Ended");
        require(_auctionId < allAuctions.length, "Invalid index");

        AuctionItem storage auctionItem = allAuctions[_auctionId];

        require(msg.value > auctionItem.currentBidPrice, "Low bid price");

        require(msg.sender != auctionItem.creator, "Creator cant bid");

        address newBidOwner = msg.sender;

        auctionItem.currentBidOwner = newBidOwner;
        auctionItem.currentBidPrice = msg.value;
        auctionItem.bidCount++;

        fundsByBidder[_auctionId][msg.sender] = msg.value;

        emit BidPlaced(_auctionId, msg.sender);

        return true;
    }

    /// @notice Cancels an auction before the auciton ends.
    function cancelAuction(uint _auctionId) external onlyCreator(_auctionId) {
        require(isOpen(_auctionId), "Auction Ended");
        require(_auctionId < allAuctions.length, "Invalid index");
        AuctionItem memory auctionItem = allAuctions[_auctionId];

        require(auctionItem.bidCount != 0, "No bid made");

        uint256 currentBidPrice = auctionItem.currentBidPrice;

        _withdraw(msg.sender, currentBidPrice);

        _claimNft(auctionItem, auctionItem.currentBidOwner);

        emit AuctionCanceled(_auctionId);
    }

    ///@notice Claims nft for the winner of the auction.
    function claimNft(uint _auctionId) external nonReentrant {
        require(!isOpen(_auctionId), "Auction Open");
        AuctionItem memory auctionItem = allAuctions[_auctionId];

        require(msg.sender == auctionItem.currentBidOwner, "Not Bidder");
        _claimNft(auctionItem, auctionItem.currentBidOwner);

        emit NftClaimed(_auctionId, auctionItem.nftID);
    }

    ///@notice Owner of the auction can withdraw highest bidder funds.
    function claimCreatorFunds(
        uint256 _auctionId
    ) external nonReentrant onlyCreator(_auctionId) {
        require(!isOpen(_auctionId), "Auction Open");
        AuctionItem memory auctionItem = allAuctions[_auctionId];
        uint256 amountToSend = auctionItem.currentBidPrice;
        _withdraw(msg.sender, amountToSend);

        emit CreatorFundsClaimed(_auctionId, amountToSend);
        delete allAuctions[auctionItem.index];
    }

    //@notice Unsuccessful bidders can withdraw their funds
    function withdrawFundsByBidder(uint _auctionId) external nonReentrant {
        require(!isOpen(_auctionId), "Auction Open");
        uint256 withdrawAmount = fundsByBidder[_auctionId][msg.sender];

        require(withdrawAmount != 0, "No funds to withdraw");

        fundsByBidder[_auctionId][msg.sender] = 0;

        _withdraw(msg.sender, withdrawAmount);

        emit FundsWithdrawn(_auctionId, msg.sender, withdrawAmount);
    }

    ///@notice nft is refunded when number of bids is zero and auction has also ended.
    function refundNFt(
        uint256 _auctionId
    ) external nonReentrant onlyCreator(_auctionId) {
        require(!isOpen(_auctionId), "Auction Open");
        AuctionItem memory auctionItem = allAuctions[_auctionId];

        require(auctionItem.bidCount == 0, "Cant refund");

        _claimNft(auctionItem, msg.sender);

        emit NftRefunded(_auctionId, msg.sender);
    }

    function _claimNft(
        AuctionItem memory _auctionItem,
        address _receiver
    ) internal {
        fundsByBidder[_auctionItem.index][_auctionItem.currentBidOwner] = 0;

        IERC721(_auctionItem.nft).safeTransferFrom(
            address(this),
            _receiver,
            _auctionItem.nftID
        );
    }

    function _withdraw(address _receiver, uint amount) internal {
        (bool sent, ) = _receiver.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }

    function getTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function isOpen(uint256 _auctionId) private view returns (bool) {
        AuctionItem memory auctionItem = allAuctions[_auctionId];

        if (block.timestamp >= auctionItem.endAuction) return false;
        return true;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
