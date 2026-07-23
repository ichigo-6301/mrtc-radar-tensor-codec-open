function main_cross_check_matlab_c()
% This historical entrypoint inventories MATLAB artifacts only. It does not
% execute the C model or prove MATLAB/C equality. The authoritative executable
% cross-check is: make -C ref_model/c test
root = mrtc_repo_root();
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
    rows = [rows; table(string(cases(k).name), nbytes, true, true, ...
        'VariableNames', {'case_name','matlab_compressed_bytes', ...
        'decoded_csv_present','inventory_pass'})]; %#ok<AGROW>
end
writetable(rows, fullfile(res_dir, 'summary_matlab_vector_inventory.csv'));
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
