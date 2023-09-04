use starknet::ContractAddress;
use array::ArrayTrait;

#[derive(Drop, Copy, Serde, PartialEq)]
struct Route {
    token_from: ContractAddress,
    token_to: ContractAddress,
    exchange_address: ContractAddress,
    percent: felt252
}

#[starknet::interface]
trait IAVNUExchange<TStorage> {
    fn initializer(
        ref self: TStorage,
        owner: ContractAddress,
        fee_collector_address: ContractAddress
    );
    fn getName(
        self: @TStorage,
        owner: ContractAddress,
        fee_collector_address: ContractAddress
    ) -> felt252;
    fn getAdapterClassHash(self: @TStorage, exchange_address: felt252) -> felt252;
    fn getFeeCollectorAddress(self: @TStorage) -> felt252;

    fn multi_route_swap(
        ref self: TStorage,
        token_from_address: ContractAddress,
        token_from_amount: u256,
        token_to_address: ContractAddress,
        token_to_amount: u256,
        token_to_min_amount: u256,
        beneficiary: ContractAddress,
        integrator_fee_amount_bps: felt252,
        integrator_fee_recipient: ContractAddress,
        routes: Array<Route>,
    ) -> felt252;

    fn setAdapterClassHash(
        ref self: TStorage,
        exchange_address: ContractAddress,
        adapter_class_hash: felt252
    );

    fn setFeeCollectorAddress(
        ref self: TStorage,
        new_fee_collector_address: ContractAddress,
    );
}


#[starknet::interface]
trait IAcSith<TStorage> {

    /// IERC20 functions
    fn name(self: @TStorage) -> felt252;
    fn symbol(self: @TStorage) -> felt252;
    fn decimals(self: @TStorage) -> u8;
    fn total_supply(self: @TStorage) -> u256;
    fn totalSupply(self: @TStorage) -> u256;
    fn balance_of(self: @TStorage, account: ContractAddress) -> u256;
    fn balanceOf(self: @TStorage, account: ContractAddress) -> u256;
    fn allowance(self: @TStorage, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TStorage, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    fn transferFrom(
        ref self: TStorage, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

    fn approve(ref self: TStorage, spender: ContractAddress, amount: u256) -> bool;

    /// ERC4626-specific functions
    fn asset(self: @TStorage) -> ContractAddress;
    fn total_assets(self: @TStorage) -> u256;
    fn convert_to_shares(self: @TStorage, assets: u256) -> u256;
    fn convert_to_assets(self: @TStorage, shares: u256) -> u256;
    fn max_deposit(self: @TStorage, amount: u256) -> u256;
    fn preview_deposit(self: @TStorage, assets: u256) -> u256;
    fn deposit(ref self: TStorage, assets: u256, receiver: ContractAddress) -> u256;
    fn max_mint(self: @TStorage, receiver: ContractAddress) -> u256;
    fn preview_mint(self: @TStorage, shares: u256) -> u256;
    fn mint(ref self: TStorage, shares: u256, receiver: ContractAddress, ) -> u256;
    fn max_withdraw(self: @TStorage, owner: ContractAddress) -> u256;
    fn preview_withdraw(self: @TStorage, assets: u256) -> u256;
    fn withdraw(ref self: TStorage, assets: u256, receiver: ContractAddress, owner: ContractAddress) -> u256;
    fn max_redeem(self: @TStorage, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TStorage, shares: u256) -> u256;
    fn redeem(ref self: TStorage, shares: u256, receiver: ContractAddress, owner: ContractAddress) -> u256;
    fn compound(ref self: TStorage,
                token_from_address: ContractAddress,
                token_from_amount: u256,
                token_to_address: ContractAddress,
                token_to_amount: u256,
                token_to_min_amount: u256,
                beneficiary: ContractAddress,
                integrator_fee_amount_bps: felt252,
                integrator_fee_recipient: ContractAddress,
                routes: Array<Route>);

    // Ownable 
    fn owner(self: @TStorage) -> ContractAddress;
    fn transfer_ownership(ref self: TStorage, new_owner: starknet::ContractAddress);
    fn renounce_ownership(ref self: TStorage);


    // SithSwap setters @ views
    fn set_allowed_slippage(ref self: TStorage, allowed_slippage: u256);
    fn set_fee(ref self: TStorage, fee: u256);
    fn set_fee_recipient(ref self: TStorage, fee_recipient: ContractAddress);
    fn set_router(ref self: TStorage, router: ContractAddress);
    fn set_avnu(ref self: TStorage, router: ContractAddress);

    fn get_allowed_slippage(self: @TStorage) -> u256;
    fn get_fee(self: @TStorage) -> u256;
    fn get_fee_recipient(self: @TStorage) -> ContractAddress;
    fn get_router(self: @TStorage) -> ContractAddress;
    fn get_avnu(self: @TStorage) -> ContractAddress;
}

#[starknet::contract]
mod AcSith {
    use super::{IAcSith, IAVNUExchangeDispatcher, IAVNUExchangeDispatcherTrait, ContractAddress, Route};
    use token_sender::erc20::erc20::{IERC20Dispatcher, IERC20DispatcherTrait, ERC20};
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use starknet::get_block_timestamp;
    use zeroable::Zeroable;
    use traits::Into;
    use traits::TryInto;
    use option::OptionTrait;
    use integer::BoundedInt;
    use debug::PrintTrait;
    use token_sender::maths::{MathRounding, mul_div_down};
    use token_sender::sithswap::sithswap::{ILpTokenDispatcher, ILpTokenDispatcherTrait, IRouterDispatcher, IRouterDispatcherTrait};
    use token_sender::access::ownable;
    use token_sender::access::ownable::{Ownable, IOwnable};
    use token_sender::access::ownable::Ownable::{
        ModifierTrait as OwnableModifierTrait, HelperTrait as OwnableHelperTrait,
    };
    use array::{ArrayTrait};
    const WAD: u256 = 1000000000000000000;

    #[storage]
    struct Storage {
        _asset: ContractAddress,
        _fees: u256, // Given in WAD 100% = 10^18
        _fees_recipient: ContractAddress,
        _router: ContractAddress,
        _avnu: ContractAddress,
        _allowed_slippage: u256
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        Withdraw: Withdraw,
        Rebalance: Rebalance,
        Compound: Compound
    }
    

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        caller: ContractAddress,
        receiver: ContractAddress,
        assets: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        caller: ContractAddress,
        receiver: ContractAddress,
        owner: ContractAddress,
        assets: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Rebalance {
        caller: ContractAddress,
        asset: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Compound {
        is_swap_required: bool,
        token_sell: ContractAddress,
        amount_sell: u256,
        yields_obtained: u256,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        fees: u256,
        name: felt252,
        symbol: felt252,
        asset: ContractAddress,
        fee_recipient: ContractAddress,
        router: ContractAddress,
        avnu: ContractAddress,
        owner: ContractAddress,
        allowed_slippage: u256
    ) {
        self._initializer(fees, name, symbol, asset, fee_recipient, router, avnu, owner, allowed_slippage);
    }


    #[external(v0)]
    impl AcSithImpl of IAcSith<ContractState> {
        // ERC20 implementation

        fn name(self: @ContractState) -> felt252 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::name(@state)
        }

        fn symbol(self: @ContractState) -> felt252 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::symbol(@state)
        }

        fn decimals(self: @ContractState) -> u8 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::decimals(@state)
        }

        fn total_supply(self: @ContractState) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::total_supply(@state)
        }

        fn totalSupply(self: @ContractState) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::total_supply(@state)
        }

        

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::balance_of(@state, account)
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::balance_of(@state, account)
        }


        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::allowance(@state, owner, spender)
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let mut state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::transfer(ref state, recipient, amount)
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let mut state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::transfer_from(ref state, sender, recipient, amount)
        }

        fn transferFrom(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let mut state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::transfer_from(ref state, sender, recipient, amount)
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let mut state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            ERC20::ERC20Impl::approve(ref state, spender, amount)
        }

        // ERC4626-specific implementation

        fn asset(self: @ContractState) -> ContractAddress {
            self._asset.read()
        }

        fn total_assets(self: @ContractState) -> u256 {
            self._total_assets()
        }

        fn convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            self._convert_to_shares(assets)
        }

        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            self._convert_to_assets(shares)
        }

        fn max_deposit(self: @ContractState, amount: u256) -> u256 {
            BoundedInt::<u256>::max()
        }

        fn preview_deposit(self: @ContractState, assets: u256) -> u256 {
            self._convert_to_shares(assets)
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            let mut erc20_self = ERC20::unsafe_new_contract_state();
            let shares = AcSithImpl::preview_deposit(@self, assets);
            assert(shares != 0, 'ZERO_SHARES');
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self._asset.read() };
            token.transferFrom(caller, get_contract_address(), assets);
            ERC20::InternalImpl::_mint(ref erc20_self, receiver, shares);
            self
                .emit(
                    Event::Deposit(
                        Deposit {
                            caller: caller,
                            receiver: receiver,
                            assets: assets,
                            shares: shares
                        }
                    )
                );
            shares
        }

        fn max_mint(self: @ContractState, receiver: ContractAddress) -> u256 {
            BoundedInt::<u256>::max()
        }

        fn preview_mint(self: @ContractState, shares: u256) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            let supply = ERC20::ERC20Impl::total_supply(@state);
            if supply == 0.into() {
                shares
            } else {
                (shares * self._total_assets()).div_up(supply)
            }
        }

        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let mut erc20_self = ERC20::unsafe_new_contract_state();
            let assets = AcSithImpl::preview_mint(@self, shares);
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self._asset.read() };
            token.transferFrom(caller, get_contract_address(), assets);
            ERC20::InternalImpl::_mint(ref erc20_self, receiver, shares);
            self
                .emit(
                    Event::Deposit(
                        Deposit {
                            caller: caller, receiver: receiver, assets: assets, shares: shares
                        }
                    )
                );
            shares
        }

        fn max_withdraw(self: @ContractState, owner: ContractAddress) -> u256 {
            let erc20_self = ERC20::unsafe_new_contract_state();
            self._convert_to_assets(self.balance_of(owner))
        }

        fn preview_withdraw(self: @ContractState, assets: u256) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            let supply = ERC20::ERC20Impl::total_supply(@state);
            if supply == 0.into() {
                assets
            } else {
                (assets * supply).div_up(self.total_assets())
            }
        }

        fn withdraw(
            ref self: ContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let mut erc20_self = ERC20::unsafe_new_contract_state();
            let shares = self.preview_withdraw(assets);
            if get_caller_address() != owner {
                let allowed = self.allowance(owner, get_caller_address());
                if allowed != BoundedInt::<u256>::max() {
                    let new_allowed = allowed - shares;
                    ERC20::InternalImpl::_approve(ref erc20_self, owner, get_caller_address(), new_allowed);
                }
            }
            ERC20::InternalImpl::_burn(ref erc20_self, owner, shares);
            let token = IERC20Dispatcher { contract_address: self._asset.read() };
            token.transfer(receiver, assets);
            self
                .emit(
                    Event::Withdraw(
                        Withdraw {
                            caller: get_caller_address(),
                            receiver: receiver,
                            owner: owner,
                            assets: assets,
                            shares: shares
                        }
                    )
                );
            shares
        }

        fn max_redeem(self: @ContractState, owner: ContractAddress) -> u256 {
            self.balance_of(owner)
        }

        fn preview_redeem(self: @ContractState, shares: u256) -> u256 {
            self.convert_to_assets(shares)
        }

        fn redeem(
            ref self: ContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let assets = self.preview_redeem(shares);
            let mut erc20_self = ERC20::unsafe_new_contract_state();

            assert(assets != 0.into(), 'ZERO_ASSETS');
            if get_caller_address() != owner {
                let allowed = self.allowance(owner, get_caller_address());
                if allowed != BoundedInt::<u256>::max() {
                    let new_allowed = allowed - shares;
                    ERC20::InternalImpl::_approve(ref erc20_self, owner, get_caller_address(), new_allowed);
                }
            }
            ERC20::InternalImpl::_burn(ref erc20_self, owner, shares);
            let token = IERC20Dispatcher { contract_address: self._asset.read() };
            token.transfer(receiver, assets);
            self
                .emit(
                    Event::Withdraw(
                        Withdraw {
                            caller: get_caller_address(),
                            receiver: receiver,
                            owner: owner,
                            assets: assets,
                            shares: shares
                        }
                    )
                );
            shares
        }

        
        fn compound(ref self: ContractState,
                token_from_address: ContractAddress,
                token_from_amount: u256,
                token_to_address: ContractAddress,
                token_to_amount: u256,
                token_to_min_amount: u256,
                beneficiary: ContractAddress,
                integrator_fee_amount_bps: felt252,
                integrator_fee_recipient: ContractAddress,
                routes: Array<Route>,
        ) {
            self._only_owner();
            self._compound(token_from_address, token_from_amount, token_to_address, token_to_amount, token_to_min_amount, beneficiary, integrator_fee_amount_bps, integrator_fee_recipient, routes);
        }


        // Sith Vault Setters

        fn set_allowed_slippage(ref self: ContractState, allowed_slippage: u256){
            self._only_owner();
            self._set_allowed_slippage(allowed_slippage);
        }

        fn set_fee(ref self: ContractState, fee: u256){
            self._only_owner();
            self._set_fees(fee);
        }

        fn set_fee_recipient(ref self: ContractState, fee_recipient: ContractAddress){
            self._only_owner();
            self._set_fees_recipient(fee_recipient);
        }

        fn set_router(ref self: ContractState, router: ContractAddress){
            self._only_owner();
            self._set_router(router);
        }

        fn set_avnu(ref self: ContractState, router: ContractAddress){
            self._only_owner();
            self._set_avnu(router);
        }

        
        // Sith Vault Setters

        fn get_allowed_slippage(self: @ContractState) -> u256{
            self._allowed_slippage.read()
        }

        fn get_fee(self: @ContractState) -> u256{
            self._fees.read()
        }

        fn get_fee_recipient(self: @ContractState) -> ContractAddress{
            self._fees_recipient.read()
        }

        fn get_router(self: @ContractState) -> ContractAddress{
            self._router.read()
        }

        fn get_avnu(self: @ContractState) -> ContractAddress{
            self._avnu.read()
        }


        // Ownable

        fn owner(self: @ContractState) -> ContractAddress {
            let ownable_self = Ownable::unsafe_new_contract_state();
            ownable_self.owner()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: starknet::ContractAddress) {
            let mut ownable_self = Ownable::unsafe_new_contract_state();
            ownable_self.transfer_ownership(:new_owner);
        }

        fn renounce_ownership(ref self: ContractState) {
            let mut ownable_self = Ownable::unsafe_new_contract_state();
            ownable_self.renounce_ownership();
        }
    }

    #[generate_trait]
    impl ModifierImpl of ModifierTrait {
        fn _only_owner(self: @ContractState) {
            let ownable_self = Ownable::unsafe_new_contract_state();
            ownable_self.assert_only_owner();
        }
    }

    #[generate_trait]
    #[external(v0)]
    impl UpgradeImpl of UpgradeTrait {
        fn upgrade(ref self: ContractState, new_implementation: starknet::ClassHash) {
        // Modifiers
        self._only_owner();

        // Body
        self._upgrade(:new_implementation);
        }
    }

    #[generate_trait]
    impl HelperImpl of HelperTrait {
        fn _initializer(
            ref self: ContractState,
            fees: u256,
            name: felt252,
            symbol: felt252,
            asset: ContractAddress,
            fee_recipient: ContractAddress,
            router: ContractAddress,
            avnu: ContractAddress,
            owner: ContractAddress,
            allowed_slippage: u256
        ) {
            let mut ownable_self = Ownable::unsafe_new_contract_state();
            ownable_self._transfer_ownership(new_owner: owner);
            let mut erc20_self = ERC20::unsafe_new_contract_state();
            ERC20::InternalImpl::initializer(ref erc20_self, name, symbol);
            let token = IERC20Dispatcher { contract_address: asset };
            self._asset.write(asset);
            self._set_fees(fees);
            self._set_fees_recipient(fee_recipient);
            self._set_router(router);
            self._set_avnu(avnu);
            self._set_allowed_slippage(allowed_slippage);
        }



        fn _compound(ref self: ContractState,
                token_from_address: ContractAddress,
                token_from_amount: u256,
                token_to_address: ContractAddress,
                token_to_amount: u256,
                token_to_min_amount: u256,
                beneficiary: ContractAddress,
                integrator_fee_amount_bps: felt252,
                integrator_fee_recipient: ContractAddress,
                routes: Array<Route>,
                ) {

            let underlying = IERC20Dispatcher{ contract_address: self._asset.read() };
            let sith_lp_disp_token = ILpTokenDispatcher{ contract_address: underlying.contract_address };
            sith_lp_disp_token.claimFees();

            let token_0 = sith_lp_disp_token.getToken0();
            let token_0_disp = IERC20Dispatcher { contract_address: token_0 };
            let token_1 = sith_lp_disp_token.getToken1();
            let token_1_disp = IERC20Dispatcher { contract_address: token_1 };
            

            let mut balance_0 = token_0_disp.balanceOf(get_contract_address());
            let mut balance_1 = token_1_disp.balanceOf(get_contract_address());

            let mut is_swap_required = true;
            let mut token_to_sell_disp = token_0_disp;
            let mut curent_balance_token_to_sell = balance_0;

            if(token_from_address == token_0){
            } else {
                if(token_from_address == token_1){
                    token_to_sell_disp = token_1_disp;
                    curent_balance_token_to_sell = balance_1;
                } else {
                    assert(1 == 0, 'UNKNOWN_TOKEN_FROM');
                    }
            }

            let balance512 = integer::u512 { limb0: curent_balance_token_to_sell.low, limb1: curent_balance_token_to_sell.high, limb2: 0, limb3: 0 };
            let (q, r) = integer::u512_safe_div_rem_by_u256(balance512, u256{low: 100, high: 0}.try_into().expect('0 total asset'));
            let balance512_percent = u256 { low: q.limb0, high: q.limb1 };
            if(balance512_percent > token_from_amount){
                is_swap_required = false;
            }

            if(is_swap_required == true){
                let avnu = self._avnu.read();
                // Sanity checks + approve
                assert(curent_balance_token_to_sell >= token_from_amount, 'NOT_ENOUGH_TOKEN0_FOR_TRADE');
                token_to_sell_disp.approve(avnu, token_from_amount);
                // interact with AVNU to get tokens weighted for sith pool
                let avnuDisp = IAVNUExchangeDispatcher{ contract_address: self._avnu.read() };
                let success = avnuDisp.multi_route_swap(
                    token_from_address,
                    token_from_amount,
                    token_to_address,
                    token_to_amount,
                    token_to_min_amount,
                    beneficiary,
                    integrator_fee_amount_bps,
                    integrator_fee_recipient,
                    routes
                );
                assert(success == 1, 'TRADE_NOT_SUCCESS');
                balance_0 =  token_0_disp.balanceOf(get_contract_address());
                balance_1 =  token_1_disp.balanceOf(get_contract_address());
            }

            let router = self._router.read();
            let underlying_balance_before = underlying.balanceOf(get_contract_address());

            // approve router sith
            token_0_disp.approve(router, balance_0);
            token_1_disp.approve(router, balance_1);
            
            // provide liquidity on sith
            let is_stable_pair = sith_lp_disp_token.getStable();
            let amount_0_min = mul_div_down(balance_0, self._allowed_slippage.read(),WAD);
            let amount_1_min = mul_div_down(balance_1, self._allowed_slippage.read(),WAD);
            let router_disp = IRouterDispatcher{ contract_address: router};
            router_disp.addLiquidity(
                token_0, token_1, is_stable_pair, balance_0, balance_1, amount_0_min, amount_1_min, get_contract_address(), get_block_timestamp().into()
            );

            // Distribute fees
            let underlying_balance_after = underlying.balanceOf(get_contract_address());
            let performance_fees = mul_div_down(underlying_balance_after - underlying_balance_before, self._fees.read(), WAD);
            underlying.transfer(self._fees_recipient.read(), performance_fees);
            self
            .emit(
                Event::Compound(
                    Compound {
                        is_swap_required: is_swap_required,
                        token_sell: token_from_address,
                        amount_sell: token_from_amount,
                        yields_obtained: underlying_balance_after - underlying_balance_before
                    }
                )
            );
        }

        fn _set_fees(ref self: ContractState, fees: u256) {
            assert(fees.is_non_zero(), 'ZERO_AMOUNT');
            self._fees.write(fees);
        }

        fn _set_fees_recipient(ref self: ContractState, fees_recipient: ContractAddress) {
            assert(fees_recipient.is_non_zero(), 'ZERO_ADDRESSS');
            self._fees_recipient.write(fees_recipient);
        }

        fn _set_router(ref self: ContractState, router: ContractAddress) {
            assert(router.is_non_zero(), 'ZERO_ADDRESSS');
            self._router.write(router);
        }

        fn _set_avnu(ref self: ContractState, avnu: ContractAddress) {
            assert(avnu.is_non_zero(), 'ZERO_ADDRESSS');
            self._avnu.write(avnu);
        }

        fn _set_allowed_slippage(ref self: ContractState, allowed_slippage: u256) {
            assert(allowed_slippage.is_non_zero(), 'ZERO_AMOUNT');
            self._allowed_slippage.write(allowed_slippage);
        }

        fn _total_assets(self: @ContractState) -> u256 {
            let token = IERC20Dispatcher { contract_address: self._asset.read() };
            token.balanceOf(get_contract_address()) 
        }

        fn _convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            let supply = ERC20::ERC20Impl::total_supply(@state);
            if supply == 0.into() {
                assets
            } else {
                let num  = (assets * supply);
                let value = integer::u512 { limb0: num.low, limb1: num.high, limb2: 0, limb3: 0 };
                let (q, r) = integer::u512_safe_div_rem_by_u256(value, self.total_assets().try_into().expect('0 total asset'));
                u256 { low: q.limb0, high: q.limb1 }
            }
        }

        fn _convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            let state: ERC20::ContractState = ERC20::unsafe_new_contract_state();
            let supply = ERC20::ERC20Impl::total_supply(@state);
            if supply == 0.into() {
                shares
            } else {
                let num  = (shares * self._total_assets());
                let value = integer::u512 { limb0: num.low, limb1: num.high, limb2: 0, limb3: 0 };
                let (q, r) = integer::u512_safe_div_rem_by_u256(value, supply.try_into().expect('0 supply'));
                u256 { low: q.limb0, high: q.limb1 }
            }
        }

        fn _upgrade(ref self: ContractState, new_implementation: starknet::ClassHash) {
            starknet::replace_class_syscall(new_implementation);
        }
    }
}
