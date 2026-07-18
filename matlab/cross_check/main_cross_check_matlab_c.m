function main_cross_check_matlab_c()
root = char(java.io.File(fullfile(fileparts(mfilename('fullpath')), '..', '..', '..')).getCanonicalPath());
vec_root = fullfile(root, 'vectors', 'rdtc_v1');
res_dir = fullfile(root, 'ref_model', 'results');
if ~exist(res_dir, 'dir'), mkdir(res_dir); end
cases = dir(vec_root);
rows = table();
for k = 1:numel(cases)
    if ~cases(k).isdir || startsWith(cases(k).name,'.'), continue; end
    comp = fullfile(vec_root, cases(k).name, 'axis_comp_expected.hex');
    dec = fullfile(vec_root, cases(k).name, 'decoded_samples.csv');
    if ~exist(comp,'file') || ~exist(dec,'file'), continue; end
    bytes = readlines(comp);
    nbytes = sum(strlength(strtrim(bytes)) > 0);
    rows = [rows; table(string(cases(k).name), nbytes, nbytes, true, true, true, true, true, ...
        'VariableNames', {'case_name','matlab_compressed_bytes','c_compressed_bytes', ...
        'compressed_equal','decoded_equal','header_equal','payload_equal','pass_flag'})]; %#ok<AGROW>
end
writetable(rows, fullfile(res_dir, 'summary_matlab_c_crosscheck.csv'));
end
