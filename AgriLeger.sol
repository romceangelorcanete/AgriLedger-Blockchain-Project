// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract AgriLedger {

    // ─── Enums ───────────────────────────────────────────────
    enum Role { None, Farmer, Trader, Transporter, Vendor, Admin }  //role 1-Farmer, 2-Trader, 3-Transporter, 4-Vendor 0-None
    enum ShipmentStatus { Pending, InTransit, Delivered }
    enum ProductStatus { AtFarm, WithTrader, InTransit, Delivered }

    // ─── Structs ─────────────────────────────────────────────
    struct Participant {
        address wallet;
        string  name;
        Role    role;
        bool    isActive;
    }

    struct Product {
        uint256 productId;
        string  name;
        string  productType;
        uint256 quantity;
        uint256 harvestDate;
        string  origin;
        address currentOwner;
        bool    isRegistered;
        string  qrCodeHash;
        ProductStatus status;   // FIX 4: track product stage
    }

    struct Transaction {
        uint256 txId;
        uint256 productId;
        address sender;
        address receiver;
        uint256 timestamp;
        ShipmentStatus status;
        bool    isVerified;
        string  shipmentDetails;
    }

    // ─── State ────────────────────────────────────────────────
    address public admin;

    uint256 private _productCounter;
    uint256 private _txCounter;

    mapping(address => Participant)  public participants;
    mapping(uint256 => Product)      public products;
    mapping(uint256 => Transaction)  public transactions;
    mapping(uint256 => uint256[])    public productHistory;

    // ─── Events ───────────────────────────────────────────────
    event ParticipantRegistered(address indexed wallet, string name, Role role);
    event ProductAdded(uint256 indexed productId, string name, address indexed farmer);
    event QRGenerated(uint256 indexed productId, string qrCodeHash);
    event OwnershipTransferred(uint256 indexed productId, address indexed from, address indexed to, uint256 txId);
    event ShipmentLogged(uint256 indexed txId, uint256 indexed productId, address transporter);
    event DeliveryConfirmed(uint256 indexed txId, uint256 indexed productId, address vendor);

    // ─── Modifiers ────────────────────────────────────────────
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyRole(Role _role) {
        require(participants[msg.sender].role == _role, "Wrong role");
        require(participants[msg.sender].isActive, "Inactive account");
        _;
    }

    modifier productExists(uint256 _productId) {
        require(products[_productId].isRegistered, "Product not found");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────
    constructor() {
        admin = msg.sender;
        participants[msg.sender] = Participant({
            wallet:   msg.sender,
            name:     "Admin",
            role:     Role.Admin,
            isActive: true
        });
    }

    // ─── Admin Functions ──────────────────────────────────────

    function registerParticipant(
        address _wallet,
        string  memory _name,
        Role    _role
    ) external onlyAdmin {
        require(_role != Role.None && _role != Role.Admin, "Invalid role");
        require(participants[_wallet].role == Role.None, "Already registered");

        participants[_wallet] = Participant({
            wallet:   _wallet,
            name:     _name,
            role:     _role,
            isActive: true
        });

        emit ParticipantRegistered(_wallet, _name, _role);
    }

    function deactivateParticipant(address _wallet) external onlyAdmin {
        participants[_wallet].isActive = false;
    }

    // ─── Farmer Functions ─────────────────────────────────────

    function registerProduct(
        string memory _name,
        string memory _productType,
        uint256       _quantity,
        uint256       _harvestDate,
        string memory _origin,
        string memory _qrCodeHash
    ) external onlyRole(Role.Farmer) returns (uint256) {
        _productCounter++;
        uint256 pid = _productCounter;

        products[pid] = Product({
            productId:    pid,
            name:         _name,
            productType:  _productType,
            quantity:     _quantity,
            harvestDate:  _harvestDate,
            origin:       _origin,
            currentOwner: msg.sender,
            isRegistered: true,
            qrCodeHash:   _qrCodeHash,
            status:       ProductStatus.AtFarm   // FIX 4: set initial status
        });

        emit ProductAdded(pid, _name, msg.sender);
        emit QRGenerated(pid, _qrCodeHash);

        return pid;
    }

    // ─── Trader Functions ─────────────────────────────────────

    function purchaseProduct(
        uint256 _productId,
        string  memory _details
    ) external onlyRole(Role.Trader) productExists(_productId) {
        Product storage p = products[_productId];

        // FIX 3: product must still be at farm (not yet purchased)
        require(p.status == ProductStatus.AtFarm, "Product already purchased");
        require(
            participants[p.currentOwner].role == Role.Farmer,
            "Product not sold by farmer"
        );

        _createTransaction(_productId, p.currentOwner, msg.sender, _details);
        p.currentOwner = msg.sender;
        p.status = ProductStatus.WithTrader;   // FIX 4: update status
    }

    // ─── Transporter Functions ────────────────────────────────

    function logShipment(
        uint256 _productId,
        address _destination,
        string  memory _details
    ) external onlyRole(Role.Transporter) productExists(_productId) {
        Product storage p = products[_productId];

        // FIX 1: product must be with trader before it can be shipped
        require(p.status == ProductStatus.WithTrader, "Product must be with trader first");

        // FIX 2: destination must be a registered active vendor
        require(participants[_destination].role == Role.Vendor, "Destination must be a registered vendor");
        require(participants[_destination].isActive, "Vendor is inactive");

        _txCounter++;
        uint256 tid = _txCounter;

        transactions[tid] = Transaction({
            txId:            tid,
            productId:       _productId,
            sender:          p.currentOwner,
            receiver:        _destination,
            timestamp:       block.timestamp,
            status:          ShipmentStatus.InTransit,
            isVerified:      false,
            shipmentDetails: _details
        });

        productHistory[_productId].push(tid);
        p.status = ProductStatus.InTransit;   // FIX 4: update status
        emit ShipmentLogged(tid, _productId, msg.sender);
    }

    // ─── Vendor Functions ─────────────────────────────────────

    function confirmDelivery(
        uint256 _txId
    ) external onlyRole(Role.Vendor) {
        Transaction storage t = transactions[_txId];

        require(t.receiver == msg.sender, "Not the intended receiver");
        require(t.status == ShipmentStatus.InTransit, "Not in transit");

        // FIX 1: enforce workflow — product must be InTransit
        require(
            products[t.productId].status == ProductStatus.InTransit,
            "Product not in transit"
        );

        t.status     = ShipmentStatus.Delivered;
        t.isVerified = true;

        products[t.productId].currentOwner = msg.sender;
        products[t.productId].status = ProductStatus.Delivered;   // FIX 4: update status

        emit DeliveryConfirmed(_txId, t.productId, msg.sender);
    }

    // ─── View / Query Functions ───────────────────────────────

    function getProduct(uint256 _productId)
        external view
        productExists(_productId)
        returns (Product memory)
    {
        return products[_productId];
    }

    // FIX 4: added getProductStatus() for easy stage checking
    function getProductStatus(uint256 _productId)
        external view
        productExists(_productId)
        returns (string memory)
    {
        ProductStatus s = products[_productId].status;
        if (s == ProductStatus.AtFarm)     return "At Farm";
        if (s == ProductStatus.WithTrader) return "With Trader";
        if (s == ProductStatus.InTransit)  return "In Transit";
        if (s == ProductStatus.Delivered)  return "Delivered";
        return "Unknown";
    }

    function getTransaction(uint256 _txId)
        external view
        returns (Transaction memory)
    {
        return transactions[_txId];
    }

    function getProductHistory(uint256 _productId)
        external view
        returns (uint256[] memory)
    {
        return productHistory[_productId];
    }

    function getParticipant(address _wallet)
        external view
        returns (Participant memory)
    {
        return participants[_wallet];
    }

    function getTotalProducts() external view returns (uint256) {
        return _productCounter;
    }

    function getTotalTransactions() external view returns (uint256) {
        return _txCounter;
    }

    // ─── Internal ─────────────────────────────────────────────
    function _createTransaction(
        uint256 _productId,
        address _from,
        address _to,
        string  memory _details
    ) internal returns (uint256) {
        _txCounter++;
        uint256 tid = _txCounter;

        transactions[tid] = Transaction({
            txId:            tid,
            productId:       _productId,
            sender:          _from,
            receiver:        _to,
            timestamp:       block.timestamp,
            status:          ShipmentStatus.Pending,
            isVerified:      false,
            shipmentDetails: _details
        });

        productHistory[_productId].push(tid);
        emit OwnershipTransferred(_productId, _from, _to, tid);

        return tid;
    }
}