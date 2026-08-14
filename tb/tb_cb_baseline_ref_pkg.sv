package tb_cb_baseline_ref_pkg;

  localparam int REF_MAX_ROWS = 64;
  localparam int REF_MAX_COLS = 172;

  typedef logic [31:0] fp32_t;

  function automatic fp32_t fp32_from_real(input real value);
    shortreal sr;
    begin
      sr = shortreal'(value);
      fp32_from_real = $shortrealtobits(sr);
    end
  endfunction

  function automatic real real_from_fp32(input fp32_t bits);
    shortreal sr;
    begin
      sr = $bitstoshortreal(bits);
      real_from_fp32 = sr;
    end
  endfunction

  function automatic fp32_t fp32_add(input fp32_t lhs, input fp32_t rhs);
    shortreal a;
    shortreal b;
    shortreal c;
    begin
      a = $bitstoshortreal(lhs);
      b = $bitstoshortreal(rhs);
      c = a + b;
      fp32_add = $shortrealtobits(c);
    end
  endfunction

  function automatic fp32_t fp32_mul(input fp32_t lhs, input fp32_t rhs);
    shortreal a;
    shortreal b;
    shortreal c;
    begin
      a = $bitstoshortreal(lhs);
      b = $bitstoshortreal(rhs);
      c = a * b;
      fp32_mul = $shortrealtobits(c);
    end
  endfunction

  task automatic matvec_golden_dense(
      input int rows,
      input int cols,
      input fp32_t matrix [0:REF_MAX_ROWS-1][0:REF_MAX_COLS-1],
      input fp32_t vector [0:REF_MAX_COLS-1],
      output fp32_t result [0:REF_MAX_ROWS-1]
  );
    int r;
    int c;
    fp32_t acc;
    begin
      for (r = 0; r < REF_MAX_ROWS; r = r + 1) begin
        result[r] = 32'h0000_0000;
      end

      for (r = 0; r < rows; r = r + 1) begin
        acc = 32'h0000_0000;
        for (c = 0; c < cols; c = c + 1) begin
          acc = fp32_add(acc, fp32_mul(matrix[r][c], vector[c]));
        end
        result[r] = acc;
      end
    end
  endtask

endpackage
