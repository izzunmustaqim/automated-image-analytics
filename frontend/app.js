// ==========================================
// CONFIGURATION
// ==========================================
// This will be replaced automatically by the deployment script
const API_URL = "https://ctjtdweurd.execute-api.us-east-1.amazonaws.com/dev/"; 

// ==========================================
// DOM Elements
// ==========================================
const dropZoneElement = document.getElementById("drop-zone");
const inputElement = document.getElementById("file-input");
const progressContainer = document.getElementById("progress-container");
const progressBar = document.getElementById("progress-bar");
const statusMessage = document.getElementById("upload-status");
const galleryGrid = document.getElementById("gallery-grid");
const galleryLoader = document.getElementById("gallery-loader");
const searchInput = document.getElementById("search-input");

let allImages = []; // Cache for search filtering

// ==========================================
// Initialization
// ==========================================
document.addEventListener("DOMContentLoaded", () => {
    fetchImages();
    
    // Poll for new images every 10 seconds
    setInterval(fetchImages, 10000);
});

// ==========================================
// Drag and Drop Logic
// ==========================================
dropZoneElement.addEventListener("click", () => inputElement.click());

dropZoneElement.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropZoneElement.classList.add("drop-zone--over");
});

["dragleave", "dragend"].forEach(type => {
    dropZoneElement.addEventListener(type, (e) => {
        dropZoneElement.classList.remove("drop-zone--over");
    });
});

dropZoneElement.addEventListener("drop", (e) => {
    e.preventDefault();
    dropZoneElement.classList.remove("drop-zone--over");

    if (e.dataTransfer.files.length) {
        inputElement.files = e.dataTransfer.files;
        handleFileSelect();
    }
});

inputElement.addEventListener("change", handleFileSelect);

// ==========================================
// Upload Logic
// ==========================================
async function handleFileSelect() {
    const file = inputElement.files[0];
    if (!file) return;

    if (!file.type.startsWith('image/')) {
        showStatus("Please select a valid image file (JPG/PNG)", "error");
        return;
    }

    try {
        // 1. Get Presigned URL from our API
        showStatus("Requesting secure upload link...", "info");
        const filename = `${Date.now()}_${file.name.replace(/[^a-zA-Z0-9.]/g, "_")}`;
        
        const response = await fetch(`${API_URL}upload-url`, {
            method: 'POST',
            body: JSON.stringify({ filename })
        });
        
        if (!response.ok) throw new Error("Failed to get upload URL");
        
        const data = await response.json();
        const uploadUrl = data.uploadUrl;

        // 2. Upload file directly to S3 using the presigned URL
        showStatus("Uploading image...", "info");
        await uploadToS3(uploadUrl, file);
        
        showStatus("Upload complete! Analyzing image...", "success");
        
        // Fetch images soon to show the new one
        setTimeout(fetchImages, 3000);
        
    } catch (error) {
        console.error(error);
        showStatus(`Upload failed: ${error.message}`, "error");
        progressContainer.style.display = "none";
    }
}

function uploadToS3(url, file) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open("PUT", url, true);
        xhr.setRequestHeader("Content-Type", file.type);
        
        progressContainer.style.display = "block";
        
        xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) {
                const percentComplete = (e.loaded / e.total) * 100;
                progressBar.style.width = percentComplete + "%";
            }
        };
        
        xhr.onload = () => {
            if (xhr.status === 200) {
                setTimeout(() => {
                    progressContainer.style.display = "none";
                    progressBar.style.width = "0%";
                    resolve();
                }, 500);
            } else {
                reject(new Error(`S3 returned status ${xhr.status}`));
            }
        };
        
        xhr.onerror = () => reject(new Error("Network error during upload"));
        xhr.send(file);
    });
}

function showStatus(message, type) {
    statusMessage.textContent = message;
    statusMessage.style.color = type === 'error' ? '#ef4444' : 
                               type === 'success' ? '#10b981' : 'var(--text-secondary)';
}

// ==========================================
// Gallery & Data Fetching
// ==========================================
async function fetchImages() {
    // Only show loader if we have no images yet
    if (allImages.length === 0) {
        galleryLoader.style.display = "block";
    }
    
    try {
        const response = await fetch(`${API_URL}images`);
        if (!response.ok) throw new Error("Failed to fetch images");
        
        const data = await response.json();
        allImages = data.items;
        
        // Re-apply current search filter if any
        filterGallery();
        
    } catch (error) {
        console.error("Error fetching images:", error);
        if (allImages.length === 0) {
            galleryGrid.innerHTML = `<p style="color: #ef4444; grid-column: 1/-1; text-align: center;">Failed to load images from database.</p>`;
        }
    } finally {
        galleryLoader.style.display = "none";
    }
}

function renderGallery(items) {
    if (items.length === 0) {
        galleryGrid.innerHTML = `<p style="grid-column: 1/-1; text-align: center; color: var(--text-secondary);">No images found.</p>`;
        return;
    }

    galleryGrid.innerHTML = items.map(item => {
        const date = new Date(item.UploadTimestamp).toLocaleString();
        const sizeKB = Math.round(item.FileSizeInBytes / 1024);
        
        // Generate tags HTML
        const tagsHtml = (item.DetectedLabels || [])
            .sort((a, b) => b.Confidence - a.Confidence)
            .map(label => `
                <span class="tag">
                    ${label.Name} <span class="tag-confidence">${Math.round(label.Confidence)}%</span>
                </span>
            `).join('');

        return `
            <div class="card">
                <img src="${item.ImageUrl || 'https://via.placeholder.com/300x200?text=Processing...'}" alt="${item.S3Key}" class="card-img" loading="lazy">
                <div class="card-content">
                    <h3 class="card-title" title="${item.S3Key}">${item.S3Key}</h3>
                    <div class="card-meta">
                        ${date} • ${sizeKB} KB
                    </div>
                    <div class="tags">
                        ${tagsHtml || '<span style="color: var(--text-secondary); font-size: 0.85rem;">Processing or no labels found...</span>'}
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

// ==========================================
// Search Filtering
// ==========================================
searchInput.addEventListener("input", filterGallery);

function filterGallery() {
    const query = searchInput.value.toLowerCase().trim();
    
    if (!query) {
        renderGallery(allImages);
        return;
    }
    
    const filtered = allImages.filter(item => {
        // Search by filename
        if (item.S3Key.toLowerCase().includes(query)) return true;
        
        // Search by labels
        const labels = item.DetectedLabels || [];
        return labels.some(label => label.Name.toLowerCase().includes(query));
    });
    
    renderGallery(filtered);
}
