function main_gen_rdtc_vectors(mode)
if nargin < 1
    mode = "quick";
end
mode = string(mode);
root = mrtc_repo_root();
out_root = fullfile(root, 'vectors', 'rdtc_v1');
if ~exist(out_root, 'dir')
    mkdir(out_root);
end

cases = build_cases(mode);
summary = table();

for ci = 1:numel(cases)
    c = cases(ci);
    case_dir = fullfile(out_root, char(c.name));
    if ~exist(case_dir, 'dir')
        mkdir(case_dir);
    end

    all_comp = zeros(0, 1, 'uint8');
    all_raw = zeros(0, 1, 'uint8');
    all_input = table();
    all_decoded = table();
    all_headers = table();
    block_summary = table();
    comp_ctrl = table();
    raw_ctrl = table();
    raw_bypass_blocks = 0;

    for bi = 1:numel(c.blocks)
        b = c.blocks(bi);
        [bytes, header, decoded_i, decoded_q] = encode_block(b, c.tensor_shape);
        if ~(isequal(decoded_i, b.i(:)) && isequal(decoded_q, b.q(:)))
            ii = find(decoded_i ~= b.i(:), 1, 'first');
            iq = find(decoded_q ~= b.q(:), 1, 'first');
            if isempty(ii), ii = 0; end
            if isempty(iq), iq = 0; end
            exp_i = 0; got_i = 0; exp_q = 0; got_q = 0;
            if ii > 0
                exp_i = double(b.i(ii));
                got_i = double(decoded_i(ii));
            end
            if iq > 0
                exp_q = double(b.q(iq));
                got_q = double(decoded_q(iq));
            end
            error('Decode mismatch for case %s block %s | I idx=%d exp=%d got=%d | Q idx=%d exp=%d got=%d', ...
                char(c.name), char(b.name), ii, exp_i, got_i, iq, exp_q, got_q);
        end

        block_prefix = sprintf('block_%03d', bi - 1);
        input_name = sprintf('%s_input_samples.csv', block_prefix);
        decoded_name = sprintf('%s_decoded_samples.csv', block_prefix);
        hex_name = sprintf('%s_axis_comp_expected.hex', block_prefix);
        raw_hex_name = sprintf('%s_axis_raw_in.hex', block_prefix);
        header_name = sprintf('%s_header.csv', block_prefix);

        raw_bytes = raw_payload(b.i, b.q);
        write_block_artifacts(case_dir, input_name, decoded_name, hex_name, raw_hex_name, header_name, ...
            b, bytes, raw_bytes, header, decoded_i, decoded_q);

        if bi == 1 && numel(c.blocks) == 1
            copyfile(fullfile(case_dir, input_name), fullfile(case_dir, 'input_samples.csv'));
            copyfile(fullfile(case_dir, decoded_name), fullfile(case_dir, 'decoded_samples.csv'));
            copyfile(fullfile(case_dir, hex_name), fullfile(case_dir, 'axis_comp_expected.hex'));
            copyfile(fullfile(case_dir, raw_hex_name), fullfile(case_dir, 'axis_raw_in.hex'));
            copyfile(fullfile(case_dir, header_name), fullfile(case_dir, 'block_headers.csv'));
        end

        all_comp = [all_comp; bytes(:)]; %#ok<AGROW>
        all_raw = [all_raw; raw_bytes(:)]; %#ok<AGROW>
        comp_ctrl = [comp_ctrl; stream_ctrl_table(bytes, 16, bi - 1)]; %#ok<AGROW>
        raw_ctrl = [raw_ctrl; stream_ctrl_table(raw_bytes, 16, bi - 1)]; %#ok<AGROW>

        input_tbl = table(repmat(uint32(bi - 1), numel(b.i), 1), (0:numel(b.i)-1)', b.i(:), b.q(:), ...
            'VariableNames', {'block_idx','sample_idx','i','q'});
        decoded_tbl = table(repmat(uint32(bi - 1), numel(decoded_i), 1), (0:numel(decoded_i)-1)', decoded_i(:), decoded_q(:), ...
            'VariableNames', {'block_idx','sample_idx','i','q'});
        all_input = [all_input; input_tbl]; %#ok<AGROW>
        all_decoded = [all_decoded; decoded_tbl]; %#ok<AGROW>

        header_tbl = struct2table(header);
        header_tbl.block_idx = uint32(bi - 1);
        header_tbl.block_name = string(b.name);
        all_headers = [all_headers; movevars(header_tbl, {'block_idx','block_name'}, 'Before', 1)]; %#ok<AGROW>

        raw_bypass = bitand(header.flags, uint16(1)) ~= 0;
        raw_bypass_blocks = raw_bypass_blocks + double(raw_bypass);
        summary_row = table(uint32(bi - 1), string(b.name), uint8(b.codec_mode), uint16(b.frame_id), uint16(b.block_id), ...
            uint32(numel(b.i)), uint32(numel(raw_bytes)), uint32(numel(bytes)), raw_bypass, uint8(header.rice_k), logical(b.last_block), ...
            string(input_name), string(hex_name), string(header_name), ...
            'VariableNames', {'block_idx','block_name','codec_mode','frame_id','block_id','num_samples', ...
            'raw_bytes','compressed_bytes','raw_bypass','selected_k','last_block','input_csv','hex_file','header_csv'});
        block_summary = [block_summary; summary_row]; %#ok<AGROW>
    end

    write_hex(fullfile(case_dir, 'axis_comp_expected.hex'), all_comp);
    write_hex(fullfile(case_dir, 'axis_raw_in.hex'), all_raw);
    writetable(all_input, fullfile(case_dir, 'input_samples.csv'));
    writetable(all_decoded, fullfile(case_dir, 'decoded_samples.csv'));
    writetable(all_headers, fullfile(case_dir, 'block_headers.csv'));
    writetable(block_summary, fullfile(case_dir, 'block_summary.csv'));
    writetable(comp_ctrl, fullfile(case_dir, 'axis_comp_expected_ctrl.csv'));
    writetable(raw_ctrl, fullfile(case_dir, 'axis_raw_in_ctrl.csv'));
    write_manifest(case_dir, c, block_summary, all_comp);
    write_case_readme(case_dir, c, block_summary, all_comp, raw_bypass_blocks);

    row = table(c.name, uint32(numel(c.blocks)), uint32(numel(all_raw)), uint32(numel(all_comp)), ...
        uint32(raw_bypass_blocks), true, ...
        'VariableNames', {'case_name','block_count','total_raw_bytes','total_compressed_bytes','raw_bypass_blocks','pass_flag'});
    summary = [summary; row]; %#ok<AGROW>
end

res_dir = fullfile(root, 'ref_model', 'results');
if ~exist(res_dir, 'dir')
    mkdir(res_dir);
end
writetable(summary, fullfile(res_dir, 'summary_matlab_vector_gen.csv'));
end

function root = mrtc_repo_root()
root = fileparts(mfilename('fullpath'));
for depth = 1:8
    has_release = exist(fullfile(root, 'provenance', 'release.yaml'), 'file') == 2;
    has_rtl = exist(fullfile(root, 'rtl', 'common', 'mrtc_pkg.sv'), 'file') == 2;
    if has_release && has_rtl
        return;
    end
    parent = fileparts(root);
    if strcmp(parent, root)
        break;
    end
    root = parent;
end
error('Unable to locate the MRTC-RDTC repository root from %s', mfilename('fullpath'));
end

function cases = build_cases(mode)
n = 1024;
z = zeros(n, 1, 'int16');
cases = struct('name', {}, 'tensor_shape', {}, 'blocks', {});

cases(end+1) = mk_case("smoke_zero_sparse", [1 64 16], ...
    mk_block("zero_sparse", sparse_vec(n), circshift(sparse_vec(n), 7), 1, 1, 0, 1, 1, true, 0, 0, 0));
cases(end+1) = mk_case("smoke_single_peak", [1 64 16], ...
    mk_block("single_peak", single_peak(n), -single_peak(n), 1, 1, 0, 1, 2, true, 0, 0, 0));

if mode ~= "quick"
    cases(end+1) = mk_case("smoke_random_noise", [1 64 16], ...
        mk_block("random_noise", noise_vec(n, 17), noise_vec(n, 77), 1, 1, 0, 1, 3, true, 0, 0, 0));
    cases(end+1) = mk_case("smoke_raw_bypass", [1 64 16], ...
        mk_block("raw_bypass_noise", noise_vec(n, 99), noise_vec(n, 123), 1, 1, 0, 1, 4, true, 0, 0, 0));
    cases(end+1) = mk_case("smoke_delta", [1 64 16], ...
        mk_block("delta_smooth", int16(floor((0:n-1)'/8)), int16(-floor((0:n-1)'/16)), 2, 1, 0, 1, 5, true, 0, 0, 0));
    cases(end+1) = mk_case("smoke_multi_block", [1 64 32], [ ...
        mk_block("range_tile_0", int16(mod((0:n-1)', 31) - 15), z, 1, 1, 0, 1, 6, false, 0, 0, 0), ...
        mk_block("range_tile_1_last", int16(mod((0:n-1)' * 5, 63) - 31), int16(mod((0:n-1)' * 7, 29) - 14), 2, 1, 0, 1, 7, true, 0, 0, 16) ...
        ]);
    cases(end+1) = mk_case("smoke_axis_packing", [1 64 16], ...
        mk_block("axis_pack_delta_fixedk4", int16(mod((0:n-1)' * 3, 127) - 63), int16(mod((0:n-1)' * 5, 255) - 127), 2, 0, 4, 1, 8, true, 0, 0, 0));
end
end

function c = mk_case(name, tensor_shape, blocks)
if ~isstruct(blocks)
    error('blocks must be struct array');
end
c = struct('name', string(name), 'tensor_shape', uint16(tensor_shape(:).'), 'blocks', blocks);
end

function b = mk_block(name, i, q, codec_mode, rice_mode, fixed_k, frame_id, block_id, last_block, spatial_start, doppler_start, range_start)
b = struct( ...
    'name', string(name), ...
    'i', int16(i(:)), ...
    'q', int16(q(:)), ...
    'codec_mode', codec_mode, ...
    'rice_mode', rice_mode, ...
    'fixed_k', fixed_k, ...
    'frame_id', frame_id, ...
    'block_id', block_id, ...
    'last_block', logical(last_block), ...
    'spatial_start', spatial_start, ...
    'doppler_start', doppler_start, ...
    'range_start', range_start);
end

function v = sparse_vec(n)
v = zeros(n, 1, 'int16');
v([101 513 701]) = int16([7 -12 9]);
end

function v = single_peak(n)
v = zeros(n, 1, 'int16');
v(410) = int16(1024);
v(411) = int16(256);
v(409) = int16(-128);
end

function v = noise_vec(n, seed)
if nargin < 2
    seed = 17;
end
rng(seed);
v = int16(randi([-32768 32767], n, 1));
end

function [out, h, di, dq] = encode_block(block, tensor_shape)
n = numel(block.i);
h = init_header(block, tensor_shape);
if block.codec_mode == 0
    use_raw = true;
    k = uint8(block.fixed_k);
    payload_bits = uint32(n * 32);
else
    [k, bits] = select_k(block.i, block.q, block.codec_mode, block.rice_mode, block.fixed_k);
    payload_bits = uint32(bits);
    payload_bytes_est = ceil(double(payload_bits) / 8);
    use_raw = 64 + payload_bytes_est >= n * 4;
end

if use_raw
    h.codec_mode = uint8(0);
    h.flags = bitor(h.flags, uint16(1));
    h.rice_k = k;
    payload = raw_payload(block.i, block.q);
    h.payload_bits = uint32(numel(payload) * 8);
else
    h.codec_mode = uint8(block.codec_mode);
    h.flags = bitor(h.flags, uint16(32));
    h.rice_k = k;
    payload = rice_payload(block.i, block.q, block.codec_mode, k);
    h.payload_bits = payload_bits;
end

if block.rice_mode == 1
    h.flags = bitor(h.flags, uint16(8));
end
if block.last_block
    h.flags = bitor(h.flags, uint16(2));
end
h.payload_bytes = uint32(numel(payload));
h.raw_bytes = uint32(n * 4);
header_bytes = pack_header(h);
out = [header_bytes; payload(:)];
[di, dq] = decode_block(out);
end

function h = init_header(block, tensor_shape)
h = struct();
h.magic = uint16(hex2dec('4D52'));
h.version = uint8(1);
h.header_len = uint8(64);
h.frame_id = uint16(block.frame_id);
h.block_id = uint16(block.block_id);
h.tensor_spatial_size = uint16(tensor_shape(1));
h.tensor_doppler_size = uint16(tensor_shape(2));
h.tensor_range_size = uint16(tensor_shape(3));
h.block_spatial_start = uint16(block.spatial_start);
h.block_doppler_start = uint16(block.doppler_start);
h.block_range_start = uint16(block.range_start);
h.block_spatial_len = uint8(1);
h.block_doppler_len = uint8(64);
h.block_range_len = uint16(16);
h.sample_format = uint8(1);
h.codec_mode = uint8(block.codec_mode);
h.predictor_mode = uint8(block.codec_mode);
h.rice_k = uint8(0);
h.flags = uint16(0);
h.reserved0 = uint16(0);
h.raw_bytes = uint32(4096);
h.payload_bytes = uint32(0);
h.payload_bits = uint32(0);
h.crc32 = uint32(0);
end

function b = pack_header(h)
b = zeros(64, 1, 'uint8');
put16(1, h.magic);
b(3) = h.version;
b(4) = h.header_len;
put16(5, h.frame_id);
put16(7, h.block_id);
put16(9, h.tensor_spatial_size);
put16(11, h.tensor_doppler_size);
put16(13, h.tensor_range_size);
put16(15, h.block_spatial_start);
put16(17, h.block_doppler_start);
put16(19, h.block_range_start);
b(21) = h.block_spatial_len;
b(22) = h.block_doppler_len;
put16(23, h.block_range_len);
b(25) = h.sample_format;
b(26) = h.codec_mode;
b(27) = h.predictor_mode;
b(28) = h.rice_k;
put16(29, h.flags);
put16(31, h.reserved0);
put32(33, h.raw_bytes);
put32(37, h.payload_bytes);
put32(41, h.payload_bits);
put32(45, h.crc32);
    function put16(idx, v)
        u = uint16(v);
        b(idx) = uint8(bitand(u, 255));
        b(idx + 1) = uint8(bitshift(u, -8));
    end
    function put32(idx, v)
        u = uint32(v);
        for kk = 0:3
            b(idx + kk) = uint8(bitand(bitshift(u, -8 * kk), 255));
        end
    end
end

function p = raw_payload(i, q)
n = numel(i);
p = zeros(n * 4, 1, 'uint8');
for s = 1:n
    p(4 * s - 3:4 * s - 2) = s16le(i(s));
    p(4 * s - 1:4 * s) = s16le(q(s));
end
end

function b = s16le(v)
u = typecast(int16(v), 'uint8');
b = u(:);
end

function [best_k, best_bits] = select_k(i, q, codec, mode, fixed_k)
if mode == 0
    best_k = uint8(fixed_k);
    best_bits = count_bits(i, q, codec, fixed_k);
    return;
end
best_bits = inf;
best_k = uint8(0);
for k = 0:15
    bits = count_bits(i, q, codec, k);
    if bits < best_bits
        best_bits = bits;
        best_k = uint8(k);
    end
end
end

function bits = count_bits(i, q, codec, k)
bits = sum(mapped_bits(channel_residual(i, codec), k)) + sum(mapped_bits(channel_residual(q, codec), k));
end

function r = channel_residual(x, codec)
x = int32(x(:));
pred = zeros(size(x), 'int32');
if codec == 2
    pred(2:end) = x(1:end-1);
end
r = x - pred;
end

function m = map_residual(r)
m = zeros(size(r), 'uint32');
pos = r >= 0;
m(pos) = uint32(2 .* r(pos));
m(~pos) = uint32(-2 .* r(~pos) - 1);
end

function bits = mapped_bits(r, k)
k = double(k);
m = map_residual(r);
bits = floor(double(m) ./ 2^k) + 1 + k;
end

function payload = rice_payload(i, q, codec, k)
k = double(k);
bits = [];
prev_i = int32(0);
prev_q = int32(0);
for idx = 1:numel(i)
    curr_i = int32(i(idx));
    curr_q = int32(q(idx));
    if codec == 2 && idx > 1
        residual_i = curr_i - prev_i;
        residual_q = curr_q - prev_q;
    else
        residual_i = curr_i;
        residual_q = curr_q;
    end
    bits = [bits; rice_mapped_bits(map_residual(residual_i), k)]; %#ok<AGROW>
    bits = [bits; rice_mapped_bits(map_residual(residual_q), k)]; %#ok<AGROW>
    prev_i = curr_i;
    prev_q = curr_q;
end
pad = mod(8 - mod(numel(bits), 8), 8);
bits = [bits; zeros(pad, 1)]; %#ok<AGROW>
payload = zeros(numel(bits) / 8, 1, 'uint8');
for bi = 1:numel(payload)
    byte = uint8(0);
    for bj = 1:8
        byte = bitor(byte, uint8(bits((bi - 1) * 8 + bj)) * uint8(2^(8 - bj)));
    end
    payload(bi) = byte;
end
end

function bits = rice_channel_bits(x, codec, k)
k = double(k);
r = channel_residual(x, codec);
bits = [];
for idx = 1:numel(r)
    bits = [bits; rice_mapped_bits(map_residual(r(idx)), k)]; %#ok<AGROW>
end
end

function bits = rice_mapped_bits(mapped, k)
k = double(k);
q = floor(double(mapped) / 2^k);
rem = double(mapped) - q * 2^k;
bits = [ones(q, 1); 0];
for b = k-1:-1:0
    bits = [bits; bitget(uint32(rem), b + 1)]; %#ok<AGROW>
end
end

function [i, q] = decode_block(bytes)
h = unpack_header(bytes(1:64));
payload = bytes(65:end);
n = double(h.raw_bytes) / 4;
if bitand(h.flags, uint16(1)) ~= 0
    i = zeros(n, 1, 'int16');
    q = zeros(n, 1, 'int16');
    for s = 1:n
        i(s) = typecast(uint8(payload(4 * s - 3:4 * s - 2)), 'int16');
        q(s) = typecast(uint8(payload(4 * s - 1:4 * s)), 'int16');
    end
else
    bits = bytes_to_bits(payload);
    pos = 1;
    if bitand(h.flags, uint16(32)) ~= 0
        [i, q, ~] = decode_sample_major(bits, pos, n, h.codec_mode, h.rice_k);
    else
        [i, pos] = decode_channel(bits, pos, n, h.codec_mode, h.rice_k);
        [q, ~] = decode_channel(bits, pos, n, h.codec_mode, h.rice_k);
    end
end
end

function h = unpack_header(b)
h.raw_bytes = get32(33);
h.flags = get16(29);
h.codec_mode = b(26);
h.rice_k = b(28);
    function v = get16(idx)
        v = uint16(b(idx)) + bitshift(uint16(b(idx + 1)), 8);
    end
    function v = get32(idx)
        v = uint32(0);
        for kk = 0:3
            v = v + bitshift(uint32(b(idx + kk)), 8 * kk);
        end
    end
end

function bits = bytes_to_bits(bytes)
bits = zeros(numel(bytes) * 8, 1);
for bi = 1:numel(bytes)
    for bj = 1:8
        bits((bi - 1) * 8 + bj) = bitget(bytes(bi), 9 - bj);
    end
end
end

function [x, pos] = decode_channel(bits, pos, n, codec, k)
k = double(k);
x = zeros(n, 1, 'int16');
for idx = 1:n
    q = 0;
    while bits(pos) == 1
        q = q + 1;
        pos = pos + 1;
    end
    pos = pos + 1;
    rem = 0;
    for b = 1:k
        rem = rem * 2 + bits(pos);
        pos = pos + 1;
    end
    mapped = uint32(q * 2^k + rem);
    if bitand(mapped, 1)
        r = -int32((mapped + 1) / 2);
    else
        r = int32(mapped / 2);
    end
    pred = int32(0);
    if codec == 2 && idx > 1
        pred = int32(x(idx - 1));
    end
    x(idx) = int16(pred + r);
end

function [i, q, pos] = decode_sample_major(bits, pos, n, codec, k)
k = double(k);
i = zeros(n, 1, 'int16');
q = zeros(n, 1, 'int16');
prev_i = int32(0);
prev_q = int32(0);
for idx = 1:n
    [mapped_i, pos] = decode_one_mapped(bits, pos, k);
    [mapped_q, pos] = decode_one_mapped(bits, pos, k);
    residual_i = mapped_to_residual(mapped_i);
    residual_q = mapped_to_residual(mapped_q);
    pred_i = int32(0);
    pred_q = int32(0);
    if codec == 2 && idx > 1
        pred_i = prev_i;
        pred_q = prev_q;
    end
    i(idx) = int16(pred_i + residual_i);
    q(idx) = int16(pred_q + residual_q);
    prev_i = int32(i(idx));
    prev_q = int32(q(idx));
end
end

function [mapped, pos] = decode_one_mapped(bits, pos, k)
q = 0;
while bits(pos) == 1
    q = q + 1;
    pos = pos + 1;
end
pos = pos + 1;
rem = 0;
for b = 1:k
    rem = rem * 2 + bits(pos);
    pos = pos + 1;
end
mapped = uint32(q * 2^k + rem);
end

function r = mapped_to_residual(mapped)
if bitand(mapped, 1)
    r = -int32((mapped + 1) / 2);
else
    r = int32(mapped / 2);
end
end
end

function write_block_artifacts(case_dir, input_name, decoded_name, hex_name, raw_hex_name, header_name, block, bytes, raw_bytes, header, decoded_i, decoded_q)
input_tbl = table((0:numel(block.i)-1)', block.i(:), block.q(:), 'VariableNames', {'sample_idx','i','q'});
decoded_tbl = table((0:numel(decoded_i)-1)', decoded_i(:), decoded_q(:), 'VariableNames', {'sample_idx','i','q'});
writetable(input_tbl, fullfile(case_dir, input_name));
writetable(decoded_tbl, fullfile(case_dir, decoded_name));
write_hex(fullfile(case_dir, hex_name), bytes);
write_hex(fullfile(case_dir, raw_hex_name), raw_bytes);
writetable(struct2table(header), fullfile(case_dir, header_name));
end

function ctrl = stream_ctrl_table(bytes, word_bytes, block_idx)
nwords = ceil(numel(bytes) / word_bytes);
word_idx = uint32((0:nwords-1)');
num_bytes = repmat(uint32(word_bytes), nwords, 1);
tail = mod(numel(bytes), word_bytes);
if tail ~= 0
    num_bytes(end) = uint32(tail);
end
tlast = false(nwords, 1);
tlast(end) = true;
ctrl = table(repmat(uint32(block_idx), nwords, 1), word_idx, num_bytes, tlast, ...
    'VariableNames', {'block_idx','word_idx','num_bytes','tlast'});
end

function write_manifest(case_dir, c, block_summary, all_comp)
fid = fopen(fullfile(case_dir, 'manifest.json'), 'w');
fprintf(fid, '{\n');
fprintf(fid, '  "case_name": "%s",\n', c.name);
fprintf(fid, '  "block_count": %d,\n', height(block_summary));
fprintf(fid, '  "tensor_shape": [%d, %d, %d],\n', c.tensor_shape(1), c.tensor_shape(2), c.tensor_shape(3));
fprintf(fid, '  "total_compressed_bytes": %d\n', numel(all_comp));
fprintf(fid, '}\n');
fclose(fid);
end

function write_case_readme(case_dir, c, block_summary, all_comp, raw_bypass_blocks)
fid = fopen(fullfile(case_dir, 'README_vector.md'), 'w');
fprintf(fid, '# %s\n\n', c.name);
fprintf(fid, 'RDTC v1 vector set with sample-major IQ Rice payload layout.\n\n');
fprintf(fid, '- Blocks: %d\n', height(block_summary));
fprintf(fid, '- Tensor shape: [%d, %d, %d]\n', c.tensor_shape(1), c.tensor_shape(2), c.tensor_shape(3));
fprintf(fid, '- Total compressed bytes: %d\n', numel(all_comp));
fprintf(fid, '- Raw bypass blocks: %d\n', raw_bypass_blocks);
fprintf(fid, '- Compressed ZERO_RICE/DELTA_RICE blocks set MRTC_FLAG_SAMPLE_MAJOR_IQ.\n');
fprintf(fid, '- Case-level AXI control files use 128-bit words with per-word `num_bytes` and `tlast`.\n');
fclose(fid);
end

function write_hex(path, bytes)
fid = fopen(path, 'w');
for i = 1:numel(bytes)
    fprintf(fid, '%02X\n', bytes(i));
end
fclose(fid);
end
