// Rafflux.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

// Uncomment this line to use console.log
// import "hardhat/console.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "@openzeppelin/contracts/utils/Counters.sol";

// VRF imports
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// This import could be not necessary
// This import includes functions from both ./KeeperBase.sol and
// ./interfaces/KeeperCompatibleInterface.sol
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";


contract Rafflux is VRFConsumerBaseV2, Ownable {

	using Counters for Counters.Counter;
	
	// Address in charge of accept/decline proposals. raffleFee beneficiary
	address payable _owner;
	
	// A fee every raffle creator will pay to create a new raffle
	uint raffleFee = 0.01 ether;			// 0.01 ether for testing purposes
	// After this deadline, the proposer could revoke the proposal
	uint proposalDeadline = 300 seconds;	// 5 minutes for testing purposes
	// The maximum number of tickets allowed per raffle
	uint maxTicketsPerRaffle = 10;			// 10 for testing purporses
	// The maximun time a raffle could be active
	uint maxTimeActive = 300 seconds;		// 5 minutes for testing purposes
		
	// Assets type accepted by the contract
	enum assetType {
		ERC721,
		ERC1155
	}
	
	// Info about a raffle pending to be accepted by the admin
	struct ProposedRaffle {
		address by;  			//	The address proposing a raffle
		assetType assetType;	//	The type of the asset to be raffle off
		uint assetId;			//	The id of the asset to be raffled off
		address assetContract;	//	The asset contract address
		uint price;  			//	The price of every ticket
		uint maxTickets;		//	The max number of tickets
		uint maxTimeActive;		// 	The max time the raffle will be active
		uint proposedAt;		//  The timestamp of the propose
	}
	
	// Info about a raffle accepted by the admin
	struct AcceptedRaffle {
		address by;  			//	The address of the raffle creator
		assetType assetType;	//	The type of the asset to be raffle off
		uint assetId;			//	The id of the asset to be raffled off
		address assetContract;	//	The asset contract address
		uint price;  			//	The price of every ticket
		uint maxTickets;		//	The max number of tickets
		uint maxTimeActive;		// 	The max time the raffle will be active
		uint startedAt;			//	The timestamp when raffle starts
		uint ticketsLeft;		//	The number of tickets left until sold out
		mapping(uint256 => Ticket) tickets;
	}
	
	// Info about a ticket sold for a determined raffle
	struct Ticket {
		uint ticketId;			// The ID of the ticket
		address owner;			// The address who owns the ticket
		uint256 raffleId;		// The ID of the raffle the ticket belongs to
	}
	
	// Keep track of the proposed raffles by id 
	mapping (uint256 => ProposedRaffle) public idToProposedRaffle;
	// Keep track of the accepted raffles by id 
	mapping (uint256 => AcceptedRaffle) public idToAcceptedRaffle;
	
	
	mapping(uint256 => uint256) public requestIdToRaffleId;
	
	// Keep track of every raffle proposed. This counter will be used as raffleId
	Counters.Counter public totalRaffles;
	
	// Emit an event after successfully proposing a raffle
	event NewProposedRaffle(
		uint256 raffleId,
		address by,
		assetType assetType,
		uint assetId,
		address assetContract,
		uint price,
		uint maxTickets,
		uint maxTimeActive,
		uint proposedAt
	);
	
	// Emit an event after the admin accepted a raffle
	event NewAcceptedRaffle(
		uint256 raffleId,
		address by,
		assetType assetType,
		uint assetId,
		address assetContract,		
		uint price,
		uint maxTickets,
		uint maxTimeActive,
		uint startedAt
	);
	
	// Emit an event after successfully sell a raffle ticket
	event TicketSold(uint256 indexed raffleId, uint indexed ticketId, address buyer);	
	// Emit an event when no more tickets left for a raffle
	event SoldOut(uint256 indexed raffleId, uint256 indexed requestId);
	// Emit an event when no more time left for a raffle
	event TimeOut(uint256 indexed raffleId, uint256 requestId);
	
	// Emit an event after successfully payment to the winner of a raffle
	event NewFinishedRaffle(
		uint256 raffleId,
		uint ticketId,
		address winner,
		assetType assetType,
		uint assetId,
		address assetContract,
		address creator
	);
	
	// VRF
	VRFCoordinatorV2Interface public COORDINATOR;
	uint64 public s_subscriptionId;
	//uint256 public s_requestId;
    	uint256[] public s_randomWords;
    	uint32 public callbackGasLimit = 2500000;
    	bytes32 keyhash =  0x79d3d8832d904592c0bf9818b621522c988bb8b0c05cdc3b15aea1b6e8db0c15;
	// More info: https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/
    
    
   	 // GOERLI COORDINATOR: 0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D
	constructor(/*address _vrfCoordinator*/) VRFConsumerBaseV2(0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D) {
		_owner = payable(msg.sender);
		
		COORDINATOR = VRFCoordinatorV2Interface(0x2Ca8E0C643bDe4C2E08ab1fA0da3401AdAD7734D); 
		s_subscriptionId = 7611;
	}
	
	
	// Any user could propose a new raffle
	function proposeRaffle(assetType _assetType, uint _assetId, address _assetContract, uint _price, uint _maxTickets, uint _maxTimeActive) payable external {
		require(msg.value == raffleFee, 
			"The exact amount of the fee must be paid");
		require(_assetType == assetType.ERC721 || _assetType == assetType.ERC1155, 
			"AssetTypeError");
		require(_assetContract != address(0), 
			"AssetContractAddressError");
		require(_price > 0, 
			"The price must be greater than Zero");
		require(_maxTickets < maxTicketsPerRaffle && _maxTickets > 0,
			 "TicketsAmountError");
		require(_maxTimeActive < maxTimeActive && _maxTimeActive > 0,
			 "ActiveTimeError");
		// Store the raffle proposal
		//-- uint256 raffleId = uint(keccak256(abi.encodePacked(block.timestamp, msg.sender)));
		uint256 raffleId = totalRaffles.current();
		totalRaffles.increment();
		idToProposedRaffle[raffleId] = ProposedRaffle(
			msg.sender,
			_assetType,
			_assetId,
			_assetContract,
			_price,
			_maxTickets,
			_maxTimeActive,
			block.timestamp
		);
		// Emit event after a successfull proposal
		emit NewProposedRaffle(
			raffleId,
			msg.sender,
			_assetType,
			_assetId,
			_assetContract,
			_price,
			_maxTickets,
			_maxTimeActive,
			block.timestamp
		);
	}
	
	
	// The Admin accepts a proposed raffle
	function acceptRaffle(uint256 _raffleId) external onlyOwner {
		require(block.timestamp < idToProposedRaffle[_raffleId].proposedAt + proposalDeadline,
			"Proposal deadline reached");
		
		idToAcceptedRaffle[_raffleId].by = idToProposedRaffle[_raffleId].by;
		idToAcceptedRaffle[_raffleId].assetType = idToProposedRaffle[_raffleId].assetType;
		idToAcceptedRaffle[_raffleId].assetId =	idToProposedRaffle[_raffleId].assetId;
		idToAcceptedRaffle[_raffleId].assetContract = idToProposedRaffle[_raffleId].assetContract;
		idToAcceptedRaffle[_raffleId].price = idToProposedRaffle[_raffleId].price;
		idToAcceptedRaffle[_raffleId].maxTickets = idToProposedRaffle[_raffleId].maxTickets;
		idToAcceptedRaffle[_raffleId].maxTimeActive = idToProposedRaffle[_raffleId].maxTimeActive;
		// Init the raffle timer
		idToAcceptedRaffle[_raffleId].startedAt = block.timestamp;
		// Put the tickets in the ticket machine
		idToAcceptedRaffle[_raffleId].ticketsLeft = idToProposedRaffle[_raffleId].maxTickets;
		
		_transferToContract(
			idToProposedRaffle[_raffleId].by,
			idToProposedRaffle[_raffleId].assetType,
			idToProposedRaffle[_raffleId].assetContract,
			idToProposedRaffle[_raffleId].assetId
		);
		
		emit NewAcceptedRaffle(
			_raffleId,
			idToProposedRaffle[_raffleId].by,
			idToProposedRaffle[_raffleId].assetType,
			idToProposedRaffle[_raffleId].assetId,
			idToProposedRaffle[_raffleId].assetContract,
			idToProposedRaffle[_raffleId].price,
			idToProposedRaffle[_raffleId].maxTickets,
			idToProposedRaffle[_raffleId].maxTimeActive,
			idToAcceptedRaffle[_raffleId].startedAt
		);
		
		delete idToProposedRaffle[_raffleId];
	}
	
	
	// The Admin declines a proposed raffle
	function declineRaffle(uint256 _raffleId) external onlyOwner {
		payable(idToProposedRaffle[_raffleId].by).transfer(raffleFee);
		delete idToProposedRaffle[_raffleId];
	}
	
	
	// A proposer can revoke the propose after non response from Admin
	function revokeRaffle(uint256 _raffleId) external {
		require(msg.sender == idToProposedRaffle[_raffleId].by,
			"You are not the proposer");
		require(block.timestamp > idToProposedRaffle[_raffleId].proposedAt + proposalDeadline,
			"Proposal deadline not reached yet. Admin still could accept it");
			
		payable(msg.sender).transfer(raffleFee);
		delete idToProposedRaffle[_raffleId];
	}
	
	
	// Any user could buy a ticket for an accepted raffle
	function buyTicket(uint256 _raffleId) payable external {
		require(msg.value > 0,
			"INVALID AMOUNT");
		require(msg.value == idToAcceptedRaffle[_raffleId].price,
			"INVALID AMOUNT");
		require(idToAcceptedRaffle[_raffleId].ticketsLeft > 0,
			"SOLD OUT");
		require(block.timestamp < idToAcceptedRaffle[_raffleId].startedAt + idToAcceptedRaffle[_raffleId].maxTimeActive, 
			"Deadline reached. Ended Raffle");
		
		// Transfer an amount equals to the price of the ticket to the raffle creator
		payable(idToAcceptedRaffle[_raffleId].by).transfer(msg.value);

		uint ticketId = idToAcceptedRaffle[_raffleId].maxTickets -
						idToAcceptedRaffle[_raffleId].ticketsLeft;
		idToAcceptedRaffle[_raffleId].tickets[ticketId] = Ticket(
			ticketId,
			msg.sender,
			_raffleId
		);
		
		idToAcceptedRaffle[_raffleId].ticketsLeft = idToAcceptedRaffle[_raffleId].ticketsLeft - 1;
			
		emit TicketSold(
			_raffleId,
			ticketId,
			msg.sender
		);
		
		if (idToAcceptedRaffle[_raffleId].ticketsLeft == 0) {
			uint256 requestId = _requestRandomness(_raffleId);
			emit SoldOut(_raffleId, requestId);
		}
	}
	 
	
	// Any user could buy some tickets for an accepted raffle
	function buyTickets(uint256 _raffleId, uint _totalTickets) payable external {
		require(_totalTickets > 0 && msg.value > 0,
			"TICKETS or AMOUNT cannot be Zero");
		unchecked {
			require(msg.value == _totalTickets * idToAcceptedRaffle[_raffleId].price,
				"INVALID AMOUNT");
		}
		require(idToAcceptedRaffle[_raffleId].ticketsLeft >= _totalTickets,
			"SOLD OUT or INVALID ID");
		require(block.timestamp < idToAcceptedRaffle[_raffleId].startedAt + idToAcceptedRaffle[_raffleId].maxTimeActive, 
			"Deadline reached. Ended Raffle");
		
		// Transfer an amount equals to the price of the tickets to the raffle creator
		payable(idToAcceptedRaffle[_raffleId].by).transfer(msg.value);
		
		for (uint i = 0; i < _totalTickets; i++) {
			uint ticketId = idToAcceptedRaffle[_raffleId].maxTickets -
							idToAcceptedRaffle[_raffleId].ticketsLeft;
			idToAcceptedRaffle[_raffleId].tickets[ticketId] = Ticket(
				ticketId,
				msg.sender,
				_raffleId
			);
			
			idToAcceptedRaffle[_raffleId].ticketsLeft = idToAcceptedRaffle[_raffleId].ticketsLeft - 1;
			
			emit TicketSold(
				_raffleId,
				ticketId,
				msg.sender
			);
		}
		
		if (idToAcceptedRaffle[_raffleId].ticketsLeft == 0) {
			uint256 requestId = _requestRandomness(_raffleId);
			emit SoldOut(_raffleId, requestId);
		}
	}
	
	
	// When deadline is reached, someone need to call the requestRandomness,
	// whoever do it will get 1 FREE ticket as incentive to pay the gas cost
	function requestFinishRaffle(uint256 _raffleId) external {
		require(block.timestamp > idToAcceptedRaffle[_raffleId].startedAt + idToAcceptedRaffle[_raffleId].maxTimeActive, 
			"Deadline not reached");
		require(idToAcceptedRaffle[_raffleId].ticketsLeft > 0, "SOLD OUT");
		
		// Send the FREE ticket to the tx sender
		_freeTicket(_raffleId, msg.sender);
		
		uint256 requestId = _requestRandomness(_raffleId);
		emit TimeOut(_raffleId, requestId);
	}
	
	
	// Send a FREE ticket for a raffle to an address
	function _freeTicket(uint256 _raffleId, address to) internal {
		uint ticketId = idToAcceptedRaffle[_raffleId].maxTickets -
						idToAcceptedRaffle[_raffleId].ticketsLeft;
		idToAcceptedRaffle[_raffleId].tickets[ticketId] = Ticket(
			ticketId,
			to,
			_raffleId
		);
		
		idToAcceptedRaffle[_raffleId].ticketsLeft = idToAcceptedRaffle[_raffleId].ticketsLeft - 1;
		
		emit TicketSold(
			_raffleId,
			ticketId,
			to
		);
	}
	
	
	// Request a random value to Vrf Chainlink
	function _requestRandomness(uint256 _raffleId) internal returns (uint256) {
		require(s_subscriptionId != 0, "Subscription ID not set");
        	// Will revert if subscription is not set and funded
        	uint256 requestId = COORDINATOR.requestRandomWords(
		    keyhash,
		    s_subscriptionId,
		    3, 						// minimum confirmations before response
		    callbackGasLimit,
		    1 						// `numWords` : number of random values we want
		);

		requestIdToRaffleId[requestId] = _raffleId;

		return requestId;
		//console.log("Request ID: ", s_requestId);
		// requestId looks like uint256:
		// 80023009725525451140349768621743705773526822376835636211719588211198618496446
	}
	
	
    	// This is the callback that the VRF coordinator sends the random values to
    	function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        	// randomWords looks like this uint256:
        	// 68187645017388103597074813724954069904348581739269924188458647203960383435815
		s_randomWords = _randomWords;
		
		uint256 _raffleId = requestIdToRaffleId[_requestId];
        
     		uint totalTicketsSold = idToAcceptedRaffle[_raffleId].maxTickets - idToAcceptedRaffle[_raffleId].ticketsLeft;
        	uint256 random = _randomWords[0] % totalTicketsSold; // use modulo to choose a random index.
		
		_finishRaffle(_raffleId, random);
    	}
	
	
	// The Raffle will end and the payment will send after receive a random number
	function _finishRaffle(uint256 _raffleId, uint256 _random) internal {
		require(idToAcceptedRaffle[_raffleId].ticketsLeft == 0 ||
				block.timestamp > idToAcceptedRaffle[_raffleId].startedAt + idToAcceptedRaffle[_raffleId].maxTimeActive, "Raffle still on going");
		
		uint256 ticketWinnerId = _random;
		
		_transferFromContract(
			idToAcceptedRaffle[_raffleId].tickets[ticketWinnerId].owner,
			idToAcceptedRaffle[_raffleId].assetType,
			idToAcceptedRaffle[_raffleId].assetContract,
			idToAcceptedRaffle[_raffleId].assetId
		);
				
		emit NewFinishedRaffle(
			_raffleId,
			idToAcceptedRaffle[_raffleId].tickets[ticketWinnerId].ticketId,
			idToAcceptedRaffle[_raffleId].tickets[ticketWinnerId].owner,
			idToAcceptedRaffle[_raffleId].assetType,
			idToAcceptedRaffle[_raffleId].assetId,
			idToAcceptedRaffle[_raffleId].assetContract,
			idToAcceptedRaffle[_raffleId].by	
		);
		
		delete idToAcceptedRaffle[_raffleId];
	}
	
	
	// Set the Chainlink VRF subscription ID
	function setSubscriptionId(uint64 _subscriptionId) public {
		s_subscriptionId = _subscriptionId;
	}
	
	function setCallbackGasLimit(uint32 _callbackGasLimit) public {
		callbackGasLimit = _callbackGasLimit;
	}
	
	// Setters
	function setRaffleFee(uint _raffleFee) public { raffleFee = _raffleFee; }
	
	function setMaxTicketsPerRaffle(uint _maxTicketsPerRaffle) public {
		maxTicketsPerRaffle = _maxTicketsPerRaffle;
	}
	
	function setMaxTimeActive(uint _maxTimeActive) public { 
		maxTimeActive = _maxTimeActive;
	}
	
	function setProposalDeadline(uint _proposalDeadline) public { 
		proposalDeadline = _proposalDeadline;
	}
	
	
	// Transfer the asset to be raffle off to the contract
	function _transferToContract(address _from, assetType _type, address _assetContract, uint256 _assetId) internal {
		if (_type == assetType.ERC721) {
			IERC721(_assetContract)
				.safeTransferFrom(_from, address(this), _assetId);
    	} else if (_type == assetType.ERC1155) {
			IERC1155(_assetContract)
				.safeTransferFrom(_from, address(this), _assetId, 1, "");
    	}
	}
	
	
	// Transfer the asset from the contract to the winner or to the proposer
	function _transferFromContract(address _to, assetType _type, address _assetContract, uint256 _assetId) internal {
		if (_type == assetType.ERC721) {
			IERC721(_assetContract)
				.safeTransferFrom(address(this), _to, _assetId);
    	} else if (_type == assetType.ERC1155) {
			IERC1155(_assetContract)
				.safeTransferFrom(address(this), _to, _assetId, 1, "");
    	}		
	}
	
	// Function needed to use the IERC721Receiver
    	function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        	return IERC721Receiver.onERC721Received.selector;
    	}
    
    	
	// Withdraw functions
	function withdraw() external onlyOwner {
		payable(msg.sender).transfer(address(this).balance);
	}
	
	function withdraw(uint amount) external onlyOwner {
		require(amount >= 0, "NegativeAmountError");
		payable(msg.sender).transfer(amount);
	}
}
