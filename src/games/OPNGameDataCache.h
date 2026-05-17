#pragma once

#include "../common/OPNGameTypes.h"
#include <Foundation/Foundation.h>
#include <string>
#include <vector>

namespace OPN {

class GameDataCache {
public:
    static GameDataCache &Shared();

    std::string CatalogKey(const std::string &searchQuery,
                           const std::string &sortId,
                           const std::vector<std::string> &filterIds,
                           int fetchCount) const;
    bool LoadCatalog(const std::string &key, CatalogBrowseResult &result) const;
    void SaveCatalog(const std::string &key, const CatalogBrowseResult &result) const;

    NSData *LoadImage(NSString *urlString) const;
    void SaveImage(NSString *urlString, NSData *data) const;

private:
    GameDataCache();

    NSString *m_rootPath;
    NSString *m_catalogPath;
    NSString *m_imagePath;
};

}
