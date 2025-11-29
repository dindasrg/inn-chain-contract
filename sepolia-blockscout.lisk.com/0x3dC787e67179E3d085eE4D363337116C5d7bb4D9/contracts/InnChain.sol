// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title InnChain Booking Escrow
/// @notice Escrow booking + tokenized deposit untuk hotel dengan kelas kamar (kelas global, harga flat)
contract InnChain is Ownable {
    IERC20 public stableToken;

    constructor(address _stableToken) Ownable(msg.sender) {
        require(_stableToken != address(0), "Invalid token");
        stableToken = IERC20(_stableToken);

        // -----------------------------------------------------
        // 1) Buat kelas kamar global (harga flat)
        // -----------------------------------------------------
        uint256 standardId = _createRoomClass("Standard", 10 * 1e12);
        uint256 deluxeId   = _createRoomClass("Deluxe", 20 * 1e12);
        uint256 suiteId    = _createRoomClass("Suite", 30 * 1e12);

        // -----------------------------------------------------
        // 2) Buat 4 dummy hotel + assign kelas yang dipakai
        // -----------------------------------------------------
        uint256 h1 = _createHotel("Hotel Sakura", payable(msg.sender));
        _addClassToHotel(h1, standardId);
        _addClassToHotel(h1, deluxeId);

        uint256 h2 = _createHotel("Golden Dragon Resort", payable(msg.sender));
        _addClassToHotel(h2, standardId);
        _addClassToHotel(h2, deluxeId);
        _addClassToHotel(h2, suiteId);

        uint256 h3 = _createHotel("Ocean Breeze Inn", payable(msg.sender));
        _addClassToHotel(h3, standardId);

        uint256 h4 = _createHotel("Skyline Boutique Hotel", payable(msg.sender));
        _addClassToHotel(h4, deluxeId);
        _addClassToHotel(h4, suiteId);
    }

    // =========================================================
    // ROOM CLASS (GLOBAL)
    // =========================================================

    struct RoomClass {
        bool exists;
        string name;        
        uint256 pricePerNight;
    }

    struct HotelDetails {
        uint256 id;
        string name;
        address wallet;
        uint256 classCount;
        ClassDetails[] classes;
    }

    struct ClassDetails {
        uint256 id;
        string name;
        uint256 pricePerNight;
    }

    mapping(uint256 => RoomClass) public roomClasses;
    uint256 public roomClassCount;

    event RoomClassCreated(uint256 indexed classId, string name, uint256 pricePerNight);

    function _createRoomClass(string memory name, uint256 pricePerNight)
        internal
        returns (uint256)
    {
        require(bytes(name).length > 0, "Class: empty name");
        require(pricePerNight > 0, "Class: price must > 0");

        roomClassCount++;
        roomClasses[roomClassCount] = RoomClass({
            exists: true,
            name: name,
            pricePerNight: pricePerNight
        });

        emit RoomClassCreated(roomClassCount, name, pricePerNight);
        return roomClassCount;
    }

    /// @notice Tambah kelas global baru (kalau mau nambah tipe kamar baru)
    function addGlobalRoomClass(string memory name, uint256 pricePerNight)
        external
        onlyOwner
        returns (uint256)
    {
        return _createRoomClass(name, pricePerNight);
    }

    // =========================================================
    // HOTEL
    // =========================================================

    struct Hotel {
        bool registered;
        string name;
        address payable wallet;
        uint256 classCount;
        uint256[] classIds; // refer ke RoomClass global
    }

    mapping(uint256 => Hotel) private _hotels;
    uint256 public hotelCount;

    event HotelRegistered(uint256 indexed hotelId, string name, address wallet);
    event HotelClassLinked(uint256 indexed hotelId, uint256 indexed classId);

    function _createHotel(string memory name, address payable wallet)
        internal
        returns (uint256)
    {
        require(wallet != address(0), "Hotel: invalid wallet");
        require(bytes(name).length > 0, "Hotel: empty name");

        hotelCount++;
        Hotel storage h = _hotels[hotelCount];
        h.registered = true;
        h.name = name;
        h.wallet = wallet;
        h.classCount = 0;

        emit HotelRegistered(hotelCount, name, wallet);
        return hotelCount;
    }

    /// @notice Register hotel baru
    function registerHotel(string memory name, address payable wallet)
        external
        onlyOwner
        returns (uint256)
    {
        return _createHotel(name, wallet);
    }

    /// @notice Hubungkan hotel dengan kelas kamar global tertentu
    function linkHotelToClass(uint256 hotelId, uint256 classId) external onlyOwner {
        _addClassToHotel(hotelId, classId);
    }

    function _addClassToHotel(uint256 hotelId, uint256 classId) internal {
        Hotel storage h = _hotels[hotelId];
        require(h.registered, "Hotel: not found");
        require(roomClasses[classId].exists, "Class: not found");

        h.classIds.push(classId);
        h.classCount++;

        emit HotelClassLinked(hotelId, classId);
    }

    // =========================================================
    // BOOKING + ESCROW (roomCost + deposit)
    // =========================================================

    struct Booking {
        address customer;
        uint256 hotelId;
        uint256 classId;
        uint256 nights;
        uint256 roomCost;      // pricePerNight * nights
        uint256 depositAmount; // deposit yang dikunci
        bool paidRoom;
        bool roomReleased;     // roomCost sudah dikirim ke hotel
        bool depositReleased;  // deposit sudah di-handle (refund/charge)
    }

    mapping(uint256 => Booking) private _bookings;
    uint256 public bookingCount;

    event BookingCreated(
        uint256 indexed bookingId,
        uint256 indexed hotelId,
        uint256 indexed classId,
        address customer,
        uint256 roomCost,
        uint256 depositAmount
    );

    event RoomPaymentReleased(uint256 indexed bookingId, uint256 amountToHotel);
    event DepositRefunded(uint256 indexed bookingId, uint256 amountToCustomer);
    event DepositCharged(uint256 indexed bookingId, uint256 amountToHotel, uint256 amountToCustomer);
    event FullRefund(uint256 indexed bookingId, uint256 totalRefund);

    /// @notice cek apakah hotel punya classId tertentu
    function _hotelHasClass(uint256 hotelId, uint256 classId)
        internal
        view
        returns (bool)
    {
        Hotel storage h = _hotels[hotelId];
        if (!h.registered) return false;
        for (uint256 i = 0; i < h.classIds.length; i++) {
            if (h.classIds[i] == classId) return true;
        }
        return false;
    }

    /// @notice Buat booking baru + bayar room + deposit (escrow)
    function createBooking(
        uint256 hotelId,
        uint256 classId,
        uint256 nights,
        uint256 depositAmount
    ) external returns (uint256) {
        Hotel storage h = _hotels[hotelId];
        require(h.registered, "Hotel: invalid");
        require(nights > 0, "Booking: nights must > 0");

        RoomClass storage rc = roomClasses[classId];
        require(rc.exists, "Class: invalid");
        require(_hotelHasClass(hotelId, classId), "Hotel: class not offered");

        uint256 roomCost = rc.pricePerNight * nights;
        uint256 total = roomCost + depositAmount;
        require(total > 0, "Booking: total must > 0");

        bool ok = stableToken.transferFrom(msg.sender, address(this), total);
        require(ok, "Token: transferFrom failed");

        bookingCount++;
        _bookings[bookingCount] = Booking({
            customer: msg.sender,
            hotelId: hotelId,
            classId: classId,
            nights: nights,
            roomCost: roomCost,
            depositAmount: depositAmount,
            paidRoom: true,
            roomReleased: false,
            depositReleased: false
        });

        emit BookingCreated(
            bookingCount,
            hotelId,
            classId,
            msg.sender,
            roomCost,
            depositAmount
        );
        return bookingCount;
    }

    /// @notice Hotel mengkonfirmasi check-in → roomCost dibayar ke hotel
    function confirmCheckIn(uint256 bookingId) external {
        Booking storage b = _bookings[bookingId];
        require(b.customer != address(0), "Booking: not found");

        Hotel storage h = _hotels[b.hotelId];
        require(b.paidRoom, "Booking: not paid");
        require(!b.roomReleased, "Booking: room already released");

        b.roomReleased = true;

        bool ok = stableToken.transfer(h.wallet, b.roomCost);
        require(ok, "Token: transfer to hotel failed");

        emit RoomPaymentReleased(bookingId, b.roomCost);
    }

    /// @notice Refund deposit full ke customer (tidak ada charge)
    function refundDeposit(uint256 bookingId) external {
        Booking storage b = _bookings[bookingId];
        require(b.customer != address(0), "Booking: not found");

        // Hotel storage h = _hotels[b.hotelId];
        // require(
        //     msg.sender == h.wallet || msg.sender == owner(),
        //     "Deposit: not authorized"
        // );
        require(!b.depositReleased, "Deposit: already handled");

        b.depositReleased = true;

        if (b.depositAmount > 0) {
            bool ok = stableToken.transfer(b.customer, b.depositAmount);
            require(ok, "Token: transfer refund failed");
        }

        emit DepositRefunded(bookingId, b.depositAmount);
    }

    /// @notice Hotel mengambil sebagian/semua deposit (kerusakan, minibar, dll)
    function chargeDeposit(uint256 bookingId, uint256 amount) external {
        Booking storage b = _bookings[bookingId];
        require(b.customer != address(0), "Booking: not found");

        Hotel storage h = _hotels[b.hotelId];
        require(msg.sender == h.wallet, "Deposit: only hotel");
        require(!b.depositReleased, "Deposit: already handled");
        require(amount <= b.depositAmount, "Deposit: too much");

        b.depositReleased = true;

        uint256 toHotel = amount;
        uint256 toCustomer = b.depositAmount - amount;

        if (toHotel > 0) {
            bool ok1 = stableToken.transfer(h.wallet, toHotel);
            require(ok1, "Token: transfer to hotel failed");
        }

        if (toCustomer > 0) {
            bool ok2 = stableToken.transfer(b.customer, toCustomer);
            require(ok2, "Token: transfer to customer failed");
        }

        emit DepositCharged(bookingId, toHotel, toCustomer);
    }

    /// @notice Refund full (room + deposit) ke customer (misal booking dibatalkan sebelum check-in)
    function fullRefund(uint256 bookingId) external {
        Booking storage b = _bookings[bookingId];
        require(b.customer != address(0), "Booking: not found");

        // Hotel storage h = _hotels[b.hotelId];
        // require(
        //     msg.sender == b.customer ||
        //     msg.sender == h.wallet ||
        //     msg.sender == owner(),
        //     "Refund: not authorized"
        // );
        require(!b.roomReleased, "Refund: already checked-in");

        uint256 totalRefund = b.roomCost + b.depositAmount;

        b.roomReleased = true;
        b.depositReleased = true;

        if (totalRefund > 0) {
            bool ok = stableToken.transfer(b.customer, totalRefund);
            require(ok, "Token: refund failed");
        }

        emit FullRefund(bookingId, totalRefund);
    }

    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function getHotel(uint256 hotelId)
        external
        view
        returns (bool registered, string memory name, address wallet, uint256 classCount)
    {
        Hotel storage h = _hotels[hotelId];
        return (h.registered, h.name, h.wallet, h.classCount);
    }

    function getAllHotelsWithDetails()
        external
        view
        returns (HotelDetails[] memory)
    {
        HotelDetails[] memory hotels = new HotelDetails[](hotelCount);

        for (uint256 i = 1; i <= hotelCount; i++) {
            Hotel storage h = _hotels[i];
            ClassDetails[] memory classDetails = new ClassDetails[](h.classCount);

            // Populate class details for this hotel
            for (uint256 j = 0; j < h.classCount; j++) {
                uint256 classId = h.classIds[j];
                RoomClass storage rc = roomClasses[classId];
                classDetails[j] = ClassDetails({
                    id: classId,
                    name: rc.name,
                    pricePerNight: rc.pricePerNight
                });
            }

            // Create hotel details
            hotels[i-1] = HotelDetails({
                id: i,
                name: h.name,
                wallet: h.wallet,
                classCount: h.classCount,
                classes: classDetails
            });
        }

        return hotels;
    }

    /// @notice list semua kelas global
    function getAllRoomClasses()
        external
        view
        returns (
            uint256[] memory ids,
            string[] memory names,
            uint256[] memory prices
        )
    {
        ids = new uint256[](roomClassCount);
        names = new string[](roomClassCount);
        prices = new uint256[](roomClassCount);

        for (uint256 i = 1; i <= roomClassCount; i++) {
            RoomClass storage rc = roomClasses[i];
            ids[i - 1] = i;
            names[i - 1] = rc.name;
            prices[i - 1] = rc.pricePerNight;
        }
    }

    /// @notice Kelas apa aja yang dipakai hotel ini (ID kelas global)
    function getHotelClasses(uint256 hotelId)
        external
        view
        returns (uint256[] memory)
    {
        Hotel storage h = _hotels[hotelId];
        return h.classIds;
    }

    function getBooking(uint256 bookingId)
        external
        view
        returns (
            address customer,
            uint256 hotelId,
            uint256 classId,
            uint256 nights,
            uint256 roomCost,
            uint256 depositAmount,
            bool paidRoom,
            bool roomReleased,
            bool depositReleased
        )
    {
        Booking storage b = _bookings[bookingId];
        return (
            b.customer,
            b.hotelId,
            b.classId,
            b.nights,
            b.roomCost,
            b.depositAmount,
            b.paidRoom,
            b.roomReleased,
            b.depositReleased
        );
    }
}