module Spree
  class OrderUpdater
    attr_reader :order
    delegate :payments, :line_items, :adjustments, :shipments, :update_hooks, to: :order

    def initialize(order)
      @order = order
    end

    # This is a multi-purpose method for processing logic related to changes in the Order.
    # It is meant to be called from various observers so that the Order is aware of changes
    # that affect totals and other values stored in the Order.
    #
    # This method should never do anything to the Order that results in a save call on the
    # object with callbacks (otherwise you will end up in an infinite recursion as the
    # associations try to save and then in turn try to call +update!+ again.)
    def update
      if order.completed?
        update_payment_state

        # give each of the shipments a chance to update themselves
        shipments.each { |shipment| shipment.update!(order) }
        update_shipment_state
      end

      update_totals
      run_hooks
      persist_totals
    end

    def run_hooks
      update_hooks.each { |hook| order.send hook }
    end

    # Whenever a series of adjustments are updated, this method should be called.
    # This is done currently in the LineItem and Shipment models when instances are saved.
    def update_adjustments
      order.update_column(:adjustment_total, adjustments.eligible.sum(:amount))
    end

    # Updates the following Order total values:
    #
    # +payment_total+      The total value of all finalized Payments (NOTE: non-finalized Payments are excluded)
    # +item_total+         The total value of all LineItems
    # +adjustment_total+   The total value of all adjustments (promotions, credits, etc.)
    # +total+              The so-called "order total."  This is equivalent to +item_total+ plus +adjustment_total+.
    def update_totals
      order.payment_total = payments.completed.map(&:amount).sum
      order.item_total = line_items.map(&:amount).sum
      order.shipment_total = shipments.map(&:cost).sum
      order.adjustment_total = line_items.map(&:adjustment_total).sum
      order.total = order.item_total + order.shipment_total + order.adjustment_total
    end

    def persist_totals
      order.update_attributes_without_callbacks(
        payment_state: order.payment_state,
        shipment_state: order.shipment_state,
        item_total: order.item_total,
        adjustment_total: order.adjustment_total,
        payment_total: order.payment_total,
        total: order.total
      )
    end

    # Updates the +shipment_state+ attribute according to the following logic:
    #
    # shipped   when all Shipments are in the "shipped" state
    # partial   when at least one Shipment has a state of "shipped" and there is another Shipment with a state other than "shipped"
    #           or there are InventoryUnits associated with the order that have a state of "sold" but are not associated with a Shipment.
    # ready     when all Shipments are in the "ready" state
    # backorder when there is backordered inventory associated with an order
    # pending   when all Shipments are in the "pending" state
    #
    # The +shipment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
    def update_shipment_state
      if order.backordered?
        order.shipment_state = 'backorder'
      else
        # get all the shipment states for this order
        shipment_states = shipments.states
        if shipment_states.size > 1
          # multiple shiment states means it's most likely partially shipped
          order.shipment_state = 'partial'
        else
          # will return nil if no shipments are found
          order.shipment_state = shipment_states.first
          # TODO inventory unit states?
          # if order.shipment_state && order.inventory_units.where(:shipment_id => nil).exists?
          #   shipments exist but there are unassigned inventory units
          #   order.shipment_state = 'partial'
          # end
        end
      end

      order.state_changed('shipment')
    end

    # Updates the +payment_state+ attribute according to the following logic:
    #
    # paid          when +payment_total+ is equal to +total+
    # balance_due   when +payment_total+ is less than +total+
    # credit_owed   when +payment_total+ is greater than +total+
    # failed        when most recent payment is in the failed state
    #
    # The +payment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
    def update_payment_state

      #line_item are empty when user empties cart
      if line_items.empty? || round_money(order.payment_total) < round_money(order.total)
        if payments.present? && payments.last.state == 'failed'
          order.payment_state = 'failed'
        else
          order.payment_state = 'balance_due'
        end
      elsif round_money(order.payment_total) > round_money(order.total)
        order.payment_state = 'credit_owed'
      else
        order.payment_state = 'paid'
      end

      order.state_changed('payment')
    end
    
    private

      def round_money(n)
        (n * 100).round / 100.0
      end
  end
end
