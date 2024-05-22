using Base.Filesystem
using JLD2
using JSON3
using PackageAnalyzer
using ProgressMeter
using StringEncodings
using JuliaFormatter
using BytePairEncoding

directory_path = "./tmp_code"
const STYLE_PERMUTATIONS = [
    JuliaFormatter.DefaultStyle(),
    JuliaFormatter.YASStyle(),
    JuliaFormatter.BlueStyle(),
    JuliaFormatter.SciMLStyle()
]

function list_files(directory, extension="jl")
    jl_files = []
    for (root, dirs, files) in walkdir(directory)
        for file in files
            if endswith(file, extension)
                push!(jl_files, joinpath(root, file))
            end
        end
    end
    return jl_files
end

function get_package_path(release)
    # https://github.com/JuliaEcosystem/PackageAnalyzer.jl/blob/main/src/obtain_code.jl#L41
    tree_hash = release.tree_hash
    vs = Base.version_slug(release.uuid, Base.SHA1(hex2bytes(tree_hash)))
    tail = joinpath(release.name, vs)
    return joinpath(directory_path, tail, release.subdir)
end

function get_code(release)
    path = get_package_path(release)
    return list_files(path, "jl")
end

"""
    expand_code(release)

Expand the primary file to replace all include("...") with the content of that file.
"""
function expand_code(release)
    path = get_package_path(release)
    src_path = joinpath(path, "src")
    files = list_files(src_path, "jl")

    # Skip if there's no files
    if length(files) == 0
        @warn "No files found for $(release.name)"
        return ""
    end

    primary_file_path = filter(x -> endswith(x, "$(release.name).jl"), files) |> only

    expanded_code = expand_includes(primary_file_path)

    # Validate that there are no further include statements
    rx = r"include\((.+)\)"
    include_statements = (collect ∘ eachmatch)(rx, expanded_code)

    if length(include_statements) > 0
        @warn "Found additional include statements in $(primary_file_path)"
    end

    return expanded_code
end

function expand_includes(path)
    # Check if the file exists, otherwise throw an error.
    if !isfile(path)
        throw(ArgumentError("File not found: $path"))
    end

    # Read the primary file
    src_path = dirname(path)
    primary_file = read(path, String)

    # Find all include statements in the primary file
    rx = r"include\((.+)\)"
    include_statements = eachmatch(rx, primary_file)
    include_matches = [match.match for match in include_statements]
    include_paths = [match.captures[1] for match in include_statements]

    # Eval the paths and return the results
    include_paths = [eval(Meta.parse(path)) for path in include_paths]
    include_paths = [joinpath(src_path, path) for path in include_paths]

    include_files = [expand_includes(path) for path in include_paths]

    replace_pairs = [x => y for (x, y) in zip(include_matches, include_files)]
    primary_file = replace(primary_file, replace_pairs...)
end

function get_docs(release)
    path = get_package_path(release)
    docs = list_files(path, "md")
    docs = [i for i in docs if !occursin("license", lowercase(i))]
    return docs
end

function get_licenses(package)
    license_files = package.license_files
    if size(license_files, 1) > 0
        licenses = unique(vcat([i.licenses_found for i in license_files]))
        licenses = join(licenses, ", ")
        return licenses
    end

    if size(package.licenses_in_project, 1) > 0
        licenses = unique(vcat(package.licenses_in_project))
        licenses = join(licenses, ", ")
        return licenses
    end

    return ""

end


function main()
    all_results = load("all_results.jld2")["all_results"]

    code_data = Vector{Dict}()
    ix = 0
    licenses = String["MIT",]
    permitted_licenses = ["MIT",
        "Apache-2.0",
        "MPL-2.0",
        "BSD-3-Clause",
        "BSD-3-Clause-Open-MPI",
        "Zlib",
        "ISC",
        "CC0-1.0",
        "0BSD",
        "BSL-1.0"
    ]

    #TODO: do we want to count lines of code?
    for package in all_results

        # if package.name != "DynamicNLPModels"
        #     continue
        # end

        @info "Processing $(package.name)"
        license_files = package.license_files
        if size(license_files, 1) == 0
            licenses = String[]
        else
            licenses = unique([i.licenses_found for i in license_files][1])
        end
        if !all(license -> license in permitted_licenses, licenses)
            println("Skipping $(package.name) because of licenses: $licenses")
            continue
        elseif length(licenses) == 0
            println("Skipping $(package.name) because of licenses: $licenses")
            continue
        end

        package_dict = Dict(:package_name => package.name,
            :repo => package.repo,
            :version => package.version,
            :tree_hash => package.tree_hash,
            :licenses => licenses,
        )

        # Expand the code
        try
            # Expand the code
            code = expand_code(package)

            # Try to parse it
            try
                Meta.parseall(code)
            catch e
                @warn "Unable to parse code for $(package.name): $e"
                continue
            end


        catch e
            @warn "Unable to expand code for $(package.name): $e"
            continue
        end


        # code_files = get_code(package)
        # for file in code_files
        #     text = read(file, String)
        #     new_row = copy(package_dict)

        #     if package.subdir == ""
        #         path = join(split(file, "/")[5:end], "/")
        #     else
        #         path = join([package.subdir, split(file, "/")[5:end]...], "/")
        #     end
        #     # verify that we can parse the code in modern julia
        #     #TODO: should we format the code for different experiments?
        #     try
        #         Meta.parseall(text)
        #     catch
        #         @info "unable to parse $file, skipping..."
        #         continue
        #     end

        #     # skip tiny code files
        #     #TODO: should we skip these?
        #     if length(text) < 25
        #         continue
        #     end
        #     new_row[:text] = text
        #     new_row[:size] = "$(length(text))"
        #     new_row[:path] = path
        #     new_row[:type] = "code"
        #     push!(code_data, new_row)

        #     # Generate formatted code permutations
        #     for style in STYLE_PERMUTATIONS
        #         try
        #             formatted_text = format_text(text, style)
        #             new_row[:text] = formatted_text
        #             new_row[:size] = "$(length(formatted_text))"
        #             new_row[:path] = path
        #             new_row[:type] = "code-$(style)"
        #             push!(code_data, new_row)
        #         catch e
        #             @info "unable to format $file with style $style, skipping..."
        #             continue
        #         end
        #     end
        # end

        # doc_files = get_docs(package)
        # for file in doc_files
        #     text = read(file, String)
        #     new_row = copy(package_dict)

        #     if package.subdir == ""
        #         path = join(split(file, "/")[5:end], "/")
        #     else
        #         path = join([package.subdir, split(file, "/")[5:end]...], "/")
        #     end
        #     new_row[:text] = text
        #     new_row[:size] = "$(length(text))"
        #     new_row[:path] = path
        #     new_row[:type] = "docs"
        #     push!(code_data, new_row)
        # end
    end

    open("train.jsonl", enc"UTF-8", "w") do f
        @showprogress for (ix, item) in enumerate(code_data)
            # Convert the item to JSON and write it to a new line in the file
            try
                encode(item[:text], "UTF-8")
            catch
                continue
            end

            #TODO: should we skip these?
            if length(item[:text]) < 25
                continue
            end
            row = JSON3.write(item)
            write(f, row)
            write(f, "\n")
        end
    end
end

# if abspath(PROGRAM_FILE) == @__FILE__
res = main()
# end
