module axi_llc_hit_miss_tb;

    logic clk_i;
    logic rst_ni;
    logic test_i;
    desc_t desc_i;
    logic valid_i;
    logic ready_o;

    way_ind_t spm_lock_i;
    way_ind_t flushed_i;
    bitmask_ind_t id_bitmask_i;

    lock_t w_unlock_i;
    logic w_unlock_req_i;
    logic w_unlock_gnt_o;
    lock_t r_unlock_i;
    logic r_unlock_req_i;
    logic r_unlock_gnt_o;

    localparam INDEX_WIDTH = 6; // 6-bit index
    localparam WAY_IND_WIDTH = 2; // 4 ways
    localparam TAG_WIDTH = 32 - INDEX_WIDTH - WAY_IND_WIDTH; 

    axi_llc_hit_miss # (
        // leave as defaults
    ) axi_llc_hit_miss_dut (
        .clk_i(clk_i),                 // clk
        .rst_ni(rst_ni),               // rst (async, active low)
        .test_i(test_i),               // test mode enable
        .desc_i(desc_i),               // descriptor (type desc_t)
        .valid_i(valid_i),             // input descriptor valid
        .ready_o(ready_o),             // module ready to accept new input descriptor
        
        // .desc_o(),         // ignore for now
        // .miss_valid_o(),   // ignore for now
        // .miss_ready_i(),   // ignore for now
        // .hit_valid_o(),    // ignore for now
        // .hit_ready_i(),    // ignore for now

        .spm_lock_i(spm_lock_i),       // config input (type way_ind_t)
        .flushed_i(flushed_i),         // config input (type way_ind_t)
        .id_bitmask_i(id_bitmask_i),   // config input (type bitmask_ind_t)

        // .w_unlock_i(w_unlock_i),         // unlock inputs from units (type lock_t)
        // .w_unlock_req_i(w_unlock_req_i), // unlock inputs from units
        // .w_unlock_gnt_o(w_unlock_gnt_o), // unlock inputs from units
        // .r_unlock_i(r_unlock_i),         // unlock inputs from units (type lock_t)
        // .r_unlock_req_i(r_unlock_req_i), // unlock inputs from units
        // .r_unlock_gnt_o(r_unlock_gnt_o), // unlock inputs from units

        .cnt_down_i(cnt_down_i),         // counter input to count down (type cnt_t)
        // .bist_res_o(),     // ignore for now
        // .bist_valid_o()    // ignore for now
    )

    always #5 clk = ~clk;

    initial begin
        $dumpfile("ts_plru.vcd");
        $dumpvars(0, llc_hit_miss_unit_dut);
    end

    initial begin
        clk_i = '0;
        rst_ni = '0;
        test_i = '0;
        desc_i = '0;
        valid_i = '0;

        spm_lock_i = '0; // no ways locked for now
        flushed_i = '0; // no initial flush for now
        id_bitmask_i = '0; // no locking to plru

        // none of the w_unlock/r_unlock signals are used so no need to drive
    end

    logic [TAG_WIDTH-1:0]          input_tag; // initial tag
    logic [14:0][TAG_WIDTH-1:0]     tag_tracker; // FIFO to keep track of n tags at a time
    logic [14:0][INDEX_WIDTH-1:0]   index_tracker;
    logic [14:0][WAY_IND_WIDTH-1:0] way_tracker;

   typedef struct packed {
    logic [WAY_IND_WIDTH-1:0] indicator;
    logic [INDEX_WIDTH-1:0]   index;
    logic [TAG_WIDTH-1:0]     tag;
    logic                     dirty;
   } tag_store_desc_t; // tag store descriptor

   tag_store_desc_t ts_desc;

   logic [31:0] cache_fill_ctr;

   task automatic hm_desc_from_ts_desc(input ts_desc, output hm_desc); // task to convert desired tag/store descriptor fields to the hit/miss unit higher-level descriptor from the RR arbiter
     hm_desc.flush                                = 0; // always lookup
     hm_desc.way_ind                              = ts_desc.indicator; // which way to check
     hm_desc.a_x_addr[IndexBase+:Cfg.IndexLength] = ts_desc.index;
     hm_desc.a_x_addr[TagBase+:Cfg.TagLength]     = ts_desc.tag;
     hm_desc.rw                                   = ts_desc.dirty;
   endtask

    initial begin
        input_tag = ;
        tag_tracker = '0;
        ts_desc = '0; // never dirty (don't change that field)
    end

    always begin
        // all cache lines invalid at this time
        #20;
        rst_ni = 1'b1; // lift reset
        #20;

        valid_i = 1'b1;
        $display("Initial Cache Tag Store Unit Loading")
        repeat (15) begin // pre-filling cache lines with tags to make them valid (going to result in misses and will fill tag/store unit as a result)
            @(posedge clk_i) begin
                input_tag = {input_tag << 1, input_tag[1]^input_tag[5]}; // pr tag gen from initial seed

                tag_tracker      = tag_tracker << TAG_WIDTH;
                tag_tracker[0]   = input_tag;
                way_tracker      = way_tracker << WAY_IND_WIDTH;
                way_tracker[0]   = $random(0,3); // CHECK RANGING
                index_tracker    = index_tracker << INDEX_WIDTH;
                index_tracker[0] = $random(0,63); // CHECK RANGING

                ts_desc.indicator = way_tracker[0];
                ts_desc.index     = index_tracker[0];
                ts_desc.tag       = input_tag;

                hm_desc_from_ts_desc(ts_desc, desc_i); // convert ts descriptors to hm descriptors
                $display("MISS tag: %0h, index: %0h, way: %0h", $time(), ts_desc.index, ts_desc.tag);
                $display("PLRU ACCESS: %0b, WR: %0b at time: %0t", (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req), (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req) & (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_we), $time);
            end
        end

        #20;
        valid_i = ~valid_i; // de-assert valid
        #20;
        valid_i = ~valid_i; // assert valid again

        // consecutive hits
        repeat (4) begin
            @(posedge clk_i) begin
                ts_desc.indicator = way_tracker[cache_fill_ctr];
                ts_desc.index     = index_tracker[cache_fill_ctr];
                ts_desc.tag       = tag_tracker[cache_fill_ctr];

                hm_desc_from_ts_desc(ts_desc, desc_i);

                cache_fill_ctr++;
                $display("HIT tag: %0h, index: %0h, way: %0h", $time(), ts_desc.index, ts_desc.tag);
                $display("hit indication from tag store: %0b", |(axi_llc_hit_miss.axi_llc_tag_store.hit));
                $display("PLRU ACCESS: %0b, WR: %0b at time: %0t", (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req), (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req) & (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_we), $time);
            end
        end

        // two misses in between
        repeat (2) begin
            @(posedge clk_i) begin
                ts_desc.indicator = $random(); // CHECK RANGING
                ts_desc.index     = $random(); // CHECK RANGING
                ts_desc.tag       = $random(); // CHECK RANGING

                hm_desc_from_ts_desc(ts_desc, desc_i);
                cache_fill_ctr++;

                $display("MISS tag: %0h, index: %0h, way: %0h", $time(), ts_desc.index, ts_desc.tag);
                $display("miss indication from tag store: %0b", |(axi_llc_hit_miss.axi_llc_tag_store.hit));
                $display("PLRU ACCESS: %0b, WR: %0b at time: %0t", (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req), (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req) & (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_we), $time);
            end
        end

        // back to consecutive hits
        repeat (4) begin
            @(posedge clk_i) begin
                ts_desc.indicator = way_tracker[cache_fill_ctr];
                ts_desc.index     = index_tracker[cache_fill_ctr];
                ts_desc.tag       = tag_tracker[cache_fill_ctr];

                hm_desc_from_ts_desc(ts_desc, desc_i);

                cache_fill_ctr++;
                $display("HIT tag: %0h, index: %0h, way: %0h", $time(), ts_desc.index, ts_desc.tag);
                $display("hit indication from tag store: %0b", |(axi_llc_hit_miss.axi_llc_tag_store.hit));
                $display("PLRU ACCESS: %0b, WR: %0b at time: %0t", (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req), (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req) & (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_we), $time);
            end
        end

        repeat (10) begin
            @(posedge clk_i) begin
                $display("PLRU ACCESS: %0b, WR: %0b at time: %0t", (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req), (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_req) & (axi_llc_hit_miss.axi_llc_tag_store.axi_llc_evict_box.axi_llc_plru.plru_we), $time);
            end
        end

        $finish();

    end
endmodule