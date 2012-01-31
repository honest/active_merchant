module ActiveMerchant #:nodoc:
	module Billing #:nodoc:
		class MerchantESolutionsGateway < Gateway

			TEST_URL = 'https://cert.merchante-solutions.com/mes-api/tridentApi'
			LIVE_URL = 'https://api.merchante-solutions.com/mes-api/tridentApi'
      
			# The countries the gateway supports merchants from as 2 digit ISO country codes
			self.supported_countries = ['US']
      
			# The card types supported by the payment gateway
			self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb]
      
			# The homepage URL of the gateway
			self.homepage_url = 'http://www.merchante-solutions.com/'
      
			# The name of the gateway
			self.display_name = 'Merchant e-Solutions'
      
			def initialize(options = {})
				requires!(options, :login, :password)
				@options = options
				super
			end  
      
      # This was added in order to verify new cards BEFORE their use
      # NOTE: It WILL incur a change each time it's used.
			def verify(creditcard_or_card_id, options = {})
				post = {}
				add_invoice(post, options)
				add_payment_source(post, creditcard_or_card_id, options)
				add_address(post, options)
        # Normally one would submit a dollar amount similar to the authorize
        # transaction, but MES throws a 202 error when anything other
        # than $0.00 is posted here.  Also make sure to send the verify
        # flag to the commit method so it knows how to interpret the gatewat
        # response.
				commit('A', 0, post, true)
			end

			def authorize(money, creditcard_or_card_id, options = {})
				post = {}
				add_invoice(post, options)
				add_payment_source(post, creditcard_or_card_id, options)        
				add_address(post, options)        
        add_moto_ecommerce_ind(post, options)   # This provides the 'Mail Order/Telephone Order' type on the transaction
				commit('P', money, post)
			end

			def purchase(money, creditcard_or_card_id, options = {})
				post = {}
				add_invoice(post, options)
				add_payment_source(post, creditcard_or_card_id, options)        
				add_address(post, options)   
        add_moto_ecommerce_ind(post, options)   # This provides the 'Mail Order/Telephone Order' type on the transaction
				commit('D', money, post)
			end                       
    
			def capture(money, transaction_id, options = {})
				post ={}
				post[:transaction_id] = transaction_id
				commit('S', money, post)
			end
	  
			def store(creditcard, options = {})
				post = {}
				add_creditcard(post, creditcard, options) 
				commit('T', nil, post)
			end

			def unstore(card_id)
				post = {}
				post[:card_id] = card_id
				commit('X', nil, post)
			end

			def refund(money, identification, options = {})
				commit('U', money, options.merge(:transaction_id => identification))
			end

			def credit(money, creditcard_or_card_id, options = {})
				post = {}
				add_payment_source(post, creditcard_or_card_id, options)
				commit('C', money, post)
			end

			def void(transaction_id, options = {})
				commit('V', nil, options.merge(:transaction_id => transaction_id))
			end

			private

			def add_address(post, options)
				if address = options[:billing_address] || options[:address]
					post[:cardholder_street_address] = address[:address1].to_s.gsub(/[^\w.]/, '+')
					post[:cardholder_zip] = address[:zip].to_s       
				end
			end

			def add_invoice(post, options)
				if options.has_key? :order_id
					post[:invoice_number] = options[:order_id].to_s.gsub(/[^\w.]/, '')
				end
			end
	  
      # In the MES gateway there is a concept of 'Mail Order/Telephone
      # Order' transaction type which differentiates different kinds of
      # transactions and can affect the approval rate AND the 
      # transaction cost to the merchant.  Directly from the MES API
      # documentation the codes are as follows:
      #
      # Z = Not a Mail/Telephone Order Transaction.
      # 1 = One Time Mail/Telephone Order Transaction.
      # 2 = Recurring Mail/Telephone Order Transaction.
      # 3 = Installment Payment of a Mail/Telephone Order Transaction.
      # 5 = Secure Electronic Commerce Transaction (3D Authenticated)
      # 6 = Non-Authenticated Security Transaction at a 3-D Secure- capable merchant, and
      #     merchant attempted to authenticate the cardholder using 3-D secure 
      # 7 = e-Commerce Transaction.
      #
      # Through their API MES will default to moto ecommerce type 7 
      # if no moto_ecommerce_ind is specified (naturally since it 
      # is going through the web api).  
      def add_moto_ecommerce_ind(post, options)
        if options[:moto_ecommerce_ind].present?
          post[:moto_ecommerce_ind] = options[:moto_ecommerce_ind].to_s
        end
      end

      # This method will remain the same and be able to take either
      # a string card id token (from the MES card store feature), or
      # and instance of the ActiveMerchant::Billing:CreditCard
			def add_payment_source(post, creditcard_or_card_id, options) 
				if creditcard_or_card_id.is_a?(String)  
					# using stored card
					post[:card_id] = creditcard_or_card_id
				else
					# card info is provided
					add_creditcard(post, creditcard_or_card_id, options)
				end
			end
      
      # This method was modified to take an ActiveMerchant::Billing::CreditCard
      # instance which can contain EITHER a credit card number OR a card id
      # token (provided from the card store feature of MES).  MES recommends 
      # that for live transactions, the address AND expiration dates also
      # be submitted ALONG with the card id token since they ONLY store the
      # card number (and not other data required by banks to clear the transaction).
			def add_creditcard(post, creditcard, options)  
        if creditcard.number.present?
          # If there is a card number, use it.
          post[:card_number]  = creditcard.number
        elsif creditcard.card_id.present?
          # If there is a card id, use that instead
          post[:card_id] = creditcard.card_id         
        end

				post[:cvv2] = creditcard.verification_value if creditcard.verification_value?
				post[:card_exp_date]  = expdate(creditcard)
			end
      
			def parse(body)
				results = {}
				body.split(/&/).each do |pair|
					key,val = pair.split(/=/)
					results[key] = val
				end
				results
			end        
      
      # In the standard commit, the error code that comes back
      # for monetary transactions will be "000" for success and 
      # other values for failure.  BUT for a verification 
      # (which is nonmonetary) success will be marked by an
      # error code "085".  Since THIS version of MerchantESolutions
      # was expanded to include verification transactions, then
      # a check for this needs to happen.  Start by taking an optional
      # parameter that flags if this is a verification transaction
			def commit(action, money, parameters, verify = false)
	  
				url = test? ? TEST_URL : LIVE_URL
				parameters[:transaction_amount]  = amount(money) if money unless action == 'V'
		
				response = parse( ssl_post(url, post_data(action,parameters)) )

        # Key off the verify flag passed in to the commit method.  If 
        # it is the verify method initiating the commit, then look
        # for the '085' error code to denote success.  All other
        # transactions look for '000' for success.
				Response.new(verify ? (response["error_code"] == "085") : (response["error_code"] == "000"),
          message_from(response), response, 
					:authorization => response["transaction_id"],
					:test => test?,
					:cvv_result => response["cvv2_result"],
					:avs_result => { :code => response["avs_result"] }
				)

			end
	  
			def expdate(creditcard)
				year  = sprintf("%.4i", creditcard.year)
				month = sprintf("%.2i", creditcard.month)
				"#{month}#{year[-2..-1]}"
			end

			def message_from(response)
				if response["error_code"] == "000"
					"This transaction has been approved"
				else
					response["auth_response_text"]
				end
			end
      
			def post_data(action, parameters = {})
				post = {}
				post[:profile_id] = @options[:login]
				post[:profile_key] = @options[:password]
				post[:transaction_type] = action if action

				request = post.merge(parameters).map {|key,value| "#{key}=#{CGI.escape(value.to_s)}"}.join("&")
				request
			end
		end
	end
end
	
